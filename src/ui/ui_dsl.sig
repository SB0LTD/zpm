// @zpm/ui_dsl — platform-agnostic UI component model + renderer.
//
// This is the reusable, Layer-0 extract of the BizInSpace demo's agent-card
// renderer (nexus demo `src/kernel/ui.sig`, commits 8f2c665/ba8bd72). The demo
// drew every widget through `ui_assets.fillRoundedRect` / `ui_assets.fillCircle`
// / `font_atlas.drawString` / `font_atlas.measureString`; here those four calls
// become a caller-supplied `DrawVTable` of function pointers, so the module
// never imports `gl`, `ramfb`, `font_atlas`, `ui_assets`, or any nexus module.
//
// Properties (enforced by freestanding compilation + the hermetic tests below):
//   - Pure: no `@import` of any module (std-free, no platform coupling).
//   - Allocation-free: no heap, only tiny fixed stack scratch buffers.
//   - Reentrant: no module-level mutable state touched during render.
//
// The demo's `gl.drawCardRect(...)` card background is the one GL primitive on
// the component-card path; it is folded onto `fillRoundedRect(radius=12)` here
// (see `renderCard`). Every other demo `gl.*` primitive (particles, gradient,
// title-bar divider, glow) is app background chrome drawn by the app's own
// rasterizer, outside this module.

// 0x00RRGGBB packed; the caller maps this to its framebuffer pixel format.
pub const Color = u32;

/// Text size class. The caller's `drawString`/`measureString` map these onto
/// its own font. `lineHeight` carries the demo's per-size line advances.
pub const Size = enum(u8) { small, medium, large, xlarge };

/// Per-size line height (the demo's `font_atlas.lineHeight` values).
pub fn lineHeight(size: Size) u32 {
    return switch (size) {
        .small => 16,
        .medium => 22,
        .large => 30,
        .xlarge => 44,
    };
}

/// Caller-supplied drawing surface. ui_dsl calls ONLY through these pointers.
/// `drawString` returns the advance width (so a trailing field can be placed
/// after bold text, exactly as the demo's `drawStringBold` returned the width
/// from `font_atlas.drawString`). `fillRoundedRect` with `radius == 0` degrades
/// to a plain rect — the demo relies on this for dividers and grid lines.
pub const DrawVTable = struct {
    ctx: *anyopaque,
    fillRoundedRect: *const fn (ctx: *anyopaque, x: i32, y: i32, w: i32, h: i32, radius: i32, color: Color) void,
    fillCircle: *const fn (ctx: *anyopaque, cx: i32, cy: i32, r: i32, color: Color) void,
    drawString: *const fn (ctx: *anyopaque, x: i32, y: i32, text: []const u8, color: Color, size: Size) usize,
    measureString: *const fn (ctx: *anyopaque, text: []const u8, size: Size) usize,
};

/// Palette the caller maps to its brand. Field names mirror the demo tokens.
pub const Theme = struct {
    bg: Color,
    surface: Color,
    border: Color,
    text_primary: Color,
    text_secondary: Color,
    text_muted: Color,
    accent: Color,
    accent_dim: Color,
    ok: Color,
};

// ── Parse primitives (demo-exact) ───────────────────────────────────────────

pub const Component = struct { tag: []const u8, body: []const u8 };
pub const Pair = struct { a: []const u8, b: []const u8 };

fn trimSpaces(str: []const u8) []const u8 {
    var s: usize = 0;
    var e: usize = str.len;
    while (s < e and str[s] == ' ') s += 1;
    while (e > s and str[e - 1] == ' ') e -= 1;
    return str[s..e];
}

/// An "upper tag" is 2–12 chars of `A–Z`/`0–9`/`_`/`-` (demo `isUpperTag`).
pub fn isUpperTag(str: []const u8) bool {
    if (str.len < 2 or str.len > 12) return false;
    for (str) |c| {
        if (!((c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_' or c == '-')) return false;
    }
    return true;
}

/// Split a line into `{tag, body}`: scan to the first space; if the leading
/// token is an upper tag, that is the tag and the remainder (trimmed) is the
/// body; otherwise tag = "" and the whole trimmed line is the body.
pub fn parseComponent(ln: []const u8) Component {
    var i: usize = 0;
    while (i < ln.len and ln[i] != ' ') : (i += 1) {}
    if (i < ln.len and isUpperTag(ln[0..i])) {
        return .{ .tag = ln[0..i], .body = trimSpaces(ln[i + 1 ..]) };
    }
    return .{ .tag = "", .body = trimSpaces(ln) };
}

/// Compile-time tag comparison (demo `tagEq`).
pub fn tagEq(tag: []const u8, comptime want: []const u8) bool {
    if (tag.len != want.len) return false;
    inline for (0..want.len) |i| {
        if (tag[i] != want[i]) return false;
    }
    return true;
}

/// Split body on the first `|`, trimming inner spaces around the pipe. With no
/// `|`, returns `{a = whole, b = ""}` (demo `splitPipe`).
pub fn splitPipe(str: []const u8) Pair {
    var i: usize = 0;
    while (i < str.len) : (i += 1) {
        if (str[i] == '|') {
            var ae = i;
            while (ae > 0 and str[ae - 1] == ' ') ae -= 1;
            var bs = i + 1;
            while (bs < str.len and str[bs] == ' ') bs += 1;
            return .{ .a = str[0..ae], .b = str[bs..] };
        }
    }
    return .{ .a = str, .b = str[0..0] };
}

// ── Measurement (through the vtable) ─────────────────────────────────────────

/// Measured wrapped-text height. Walks the string summing per-char advance
/// (`measureString(&[1]u8)` + 2 kerning) and wraps at `max_w`, exactly as the
/// demo's `wrappedTextHeight`. Returns `lineHeight(size)` for an empty string.
fn wrappedTextHeight(vt: *const DrawVTable, text: []const u8, max_w: u32, size: Size) i32 {
    if (text.len == 0) return @intCast(lineHeight(size));
    const lh: i32 = @intCast(lineHeight(size));
    var lines: i32 = 1;
    var line_w: u32 = 0;
    for (text) |ch| {
        const one = [_]u8{ch};
        const cw: u32 = @intCast(vt.measureString(vt.ctx, &one, size));
        if (line_w > 0 and line_w + cw > max_w) {
            lines += 1;
            line_w = cw;
        } else {
            line_w += cw + 2;
        }
    }
    return lines * lh;
}

/// Height of one DSL line laid out for `content_w` (demo `componentHeightForWidth`).
pub fn componentHeight(vt: *const DrawVTable, ln: []const u8, content_w: u32) i32 {
    if (ln.len == 0) return 0;
    const c = parseComponent(ln);
    if (tagEq(c.tag, "TITLE")) return wrappedTextHeight(vt, c.body, content_w, .medium) + 16;
    if (tagEq(c.tag, "TEXT")) return wrappedTextHeight(vt, c.body, content_w, .medium) + 10;
    if (tagEq(c.tag, "PICK")) return wrappedTextHeight(vt, c.body, content_w -| 24, .small) + 18;
    if (tagEq(c.tag, "BTN")) return 44;
    if (tagEq(c.tag, "LIST")) return wrappedTextHeight(vt, c.body, content_w -| 24, .small) + 8;
    if (tagEq(c.tag, "ROW") or tagEq(c.tag, "STAT") or tagEq(c.tag, "KV")) return wrappedTextHeight(vt, c.body, content_w, .small) + 8;
    if (tagEq(c.tag, "MAP")) return 172;
    if (tagEq(c.tag, "DIRECTIONS")) return 68;
    if (tagEq(c.tag, "IMAGE")) return 120;
    if (tagEq(c.tag, "CHART")) return 110;
    if (tagEq(c.tag, "TABLE")) return 38;
    if (tagEq(c.tag, "PROGRESS")) return 36;
    if (tagEq(c.tag, "TOGGLE")) return 30;
    if (tagEq(c.tag, "SLIDER")) return 36;
    if (tagEq(c.tag, "GRID")) return 26;
    if (tagEq(c.tag, "HEADER")) return 46;
    if (tagEq(c.tag, "BADGE")) return 32;
    if (tagEq(c.tag, "LINK")) return 38;
    if (c.tag.len > 0) return wrappedTextHeight(vt, c.body, content_w -| 72, .small) + 12;
    return wrappedTextHeight(vt, c.body, content_w, .medium) + 6;
}

/// Natural (unwrapped) width of one DSL line (demo `componentNaturalWidth`).
pub fn componentNaturalWidth(vt: *const DrawVTable, ln: []const u8) i32 {
    if (ln.len == 0) return 0;
    const c = parseComponent(ln);
    if (tagEq(c.tag, "TITLE")) return @intCast(vt.measureString(vt.ctx, c.body, .medium) + 10);
    if (tagEq(c.tag, "TEXT")) return @intCast(vt.measureString(vt.ctx, c.body, .medium));
    if (tagEq(c.tag, "PICK")) return @intCast(vt.measureString(vt.ctx, c.body, .small) + 42);
    if (tagEq(c.tag, "BTN")) return @intCast(vt.measureString(vt.ctx, c.body, .small) + 54);
    if (tagEq(c.tag, "LIST")) return @intCast(vt.measureString(vt.ctx, c.body, .small) + 28);
    if (tagEq(c.tag, "MAP") or tagEq(c.tag, "IMAGE") or tagEq(c.tag, "CHART")) return 500;
    if (tagEq(c.tag, "DIRECTIONS") or tagEq(c.tag, "TABLE")) return 420;
    if (tagEq(c.tag, "PROGRESS") or tagEq(c.tag, "SLIDER") or tagEq(c.tag, "TOGGLE")) return 360;
    if (tagEq(c.tag, "HEADER")) return @intCast(vt.measureString(vt.ctx, c.body, .large) + 10);
    if (tagEq(c.tag, "BADGE")) return @intCast(vt.measureString(vt.ctx, c.body, .small) + 30);
    if (tagEq(c.tag, "LINK") or tagEq(c.tag, "GRID")) return @intCast(vt.measureString(vt.ctx, c.body, .small) + 20);
    if (c.tag.len > 0) return @intCast(vt.measureString(vt.ctx, c.tag, .small) + vt.measureString(vt.ctx, c.body, .small) + 46);
    return @intCast(vt.measureString(vt.ctx, c.body, .medium));
}

/// Width the card wants for `text` (demo `agentCardWidth`), clamped to
/// [320, 900]. The 900/60-margin ceiling is the demo's; it needs no screen
/// width because 900 is already the hard cap the demo computed from 1920.
pub fn cardNaturalWidth(vt: *const DrawVTable, text: []const u8) i32 {
    var maxw: i32 = 300;
    var it: usize = 0;
    while (it < text.len) {
        var e = it;
        while (e < text.len and text[e] != '\n') e += 1;
        const w = componentNaturalWidth(vt, text[it..e]);
        if (w > maxw) maxw = w;
        it = if (e < text.len) e + 1 else e;
    }
    const max_card: i32 = 900;
    return @max(@min(maxw + 56, max_card), 320);
}

/// Full card height for a chosen width (demo `agentCardHeightForWidth`): 26px
/// top chrome + sum of component heights + 8px bottom.
pub fn cardHeightForWidth(vt: *const DrawVTable, text: []const u8, card_w: i32) i32 {
    const content_w: u32 = @intCast(@max(card_w - 44, 120));
    var h: i32 = 26;
    var it: usize = 0;
    while (it < text.len) {
        var e = it;
        while (e < text.len and text[e] != '\n') e += 1;
        h += componentHeight(vt, text[it..e], content_w);
        it = if (e < text.len) e + 1 else e;
    }
    return h + 8;
}

/// Card height at the card's natural width (demo `agentCardHeight`).
pub fn cardHeight(vt: *const DrawVTable, text: []const u8, card_w: i32) i32 {
    _ = card_w;
    return cardHeightForWidth(vt, text, cardNaturalWidth(vt, text));
}

// ── Rendering (through the vtable) ───────────────────────────────────────────

/// Draw text with word-wrapping; returns total height drawn (demo
/// `drawWrappedText`, medium size).
fn drawWrappedText(vt: *const DrawVTable, x: i32, y: i32, text: []const u8, max_w: u32, color: Color) i32 {
    const lh: i32 = @intCast(lineHeight(.medium));
    var cur_y = y;
    var line_start: usize = 0;
    var line_w: u32 = 0;
    for (text, 0..) |ch, idx| {
        const one = [_]u8{ch};
        const cw: u32 = @intCast(vt.measureString(vt.ctx, &one, .medium));
        if (line_w + cw > max_w and idx > line_start) {
            _ = vt.drawString(vt.ctx, x, @max(cur_y, 0), text[line_start..idx], color, .medium);
            cur_y += lh;
            line_start = idx;
            line_w = cw;
        } else {
            line_w += cw + 2;
        }
    }
    if (line_start < text.len) {
        _ = vt.drawString(vt.ctx, x, @max(cur_y, 0), text[line_start..text.len], color, .medium);
    }
    return cur_y - y + lh;
}

/// Bold = double-strike (demo `drawStringBold`): draw, then draw +1px right;
/// returns the advance width.
fn drawBold(vt: *const DrawVTable, x: i32, y: i32, text: []const u8, color: Color, size: Size) usize {
    _ = vt.drawString(vt.ctx, x, y, text, color, size);
    return vt.drawString(vt.ctx, x + 1, y, text, color, size);
}

/// Render a single DSL line within a card content column starting at (tx, y),
/// returning the next y. `bx`/`card_w` describe the enclosing card so panel
/// widgets (MAP/CHART/…) can size to it. This is the demo `renderAgentCard`
/// per-component switch, call-for-call, through the vtable + theme.
pub fn renderLine(vt: *const DrawVTable, theme: *const Theme, ln: []const u8, bx: i32, tx: i32, y_in: i32, card_w: i32, content_w: u32) i32 {
    var y = y_in;
    const c = parseComponent(ln);
    if (tagEq(c.tag, "TITLE")) {
        const used = drawWrappedText(vt, tx, y + 6, c.body, content_w, theme.text_primary);
        y += used + 16;
    } else if (tagEq(c.tag, "TEXT")) {
        const used = drawWrappedText(vt, tx, y + 2, c.body, content_w, theme.text_secondary);
        y += used + 10;
    } else if (tagEq(c.tag, "ROW")) {
        const sp = splitPipe(c.body);
        const nw = drawBold(vt, tx, y + 4, sp.a, theme.text_primary, .small);
        if (sp.b.len > 0) _ = vt.drawString(vt.ctx, tx + @as(i32, @intCast(nw)) + 12, y + 4, sp.b, theme.text_muted, .small);
        y += wrappedTextHeight(vt, c.body, content_w, .small) + 8;
    } else if (tagEq(c.tag, "PICK")) {
        const ph = wrappedTextHeight(vt, c.body, content_w -| 24, .small) + 14;
        vt.fillRoundedRect(vt.ctx, bx + 12, y, card_w - 24, ph, 8, theme.accent_dim);
        const sp = splitPipe(c.body);
        const nw = drawBold(vt, tx, y + 8, sp.a, theme.accent, .small);
        if (sp.b.len > 0) _ = vt.drawString(vt.ctx, tx + @as(i32, @intCast(nw)) + 12, y + 8, sp.b, theme.text_secondary, .small);
        y += ph + 4;
    } else if (tagEq(c.tag, "LIST")) {
        _ = vt.drawString(vt.ctx, tx, y + 4, "-", theme.accent, .small);
        const used = drawWrappedText(vt, tx + 16, y + 4, c.body, content_w -| 24, theme.text_secondary);
        y += used + 8;
    } else if (tagEq(c.tag, "STAT") or tagEq(c.tag, "KV")) {
        // KV folds into STAT (demo): muted key + bold value.
        const sp = splitPipe(c.body);
        _ = vt.drawString(vt.ctx, tx, y + 4, sp.a, theme.text_muted, .small);
        _ = drawBold(vt, tx + 170, y + 4, sp.b, theme.text_primary, .small);
        y += wrappedTextHeight(vt, c.body, content_w, .small) + 8;
    } else if (tagEq(c.tag, "BTN")) {
        const lw: i32 = @intCast(vt.measureString(vt.ctx, c.body, .small));
        vt.fillRoundedRect(vt.ctx, bx + 20, y + 2, lw + 34, 30, 10, theme.accent);
        _ = drawBold(vt, bx + 37, y + 9, c.body, theme.text_primary, .small);
        y += 44;
    } else if (tagEq(c.tag, "MAP")) {
        const mh: i32 = 160;
        const mcw = @max(card_w - 44, 200);
        vt.fillRoundedRect(vt.ctx, tx - 4, y, mcw, mh, 10, theme.surface);
        var gx2: i32 = tx + 30;
        while (gx2 < tx + mcw - 40) : (gx2 += 50) {
            vt.fillRoundedRect(vt.ctx, gx2, y + 16, 1, mh - 32, 0, theme.border);
        }
        var gy2: i32 = y + 30;
        while (gy2 < y + mh - 30) : (gy2 += 35) {
            vt.fillRoundedRect(vt.ctx, tx + 10, gy2, mcw - 24, 1, 0, theme.border);
        }
        const pcx = tx + @divTrunc(mcw, 2);
        const pcy = y + @divTrunc(mh, 2) - 8;
        vt.fillCircle(vt.ctx, pcx, pcy, 12, theme.accent);
        vt.fillCircle(vt.ctx, pcx, pcy, 6, theme.text_primary);
        _ = vt.drawString(vt.ctx, tx + 8, y + mh - 24, c.body, theme.text_secondary, .small);
        _ = vt.drawString(vt.ctx, tx + mcw - 42, y + 8, "MAP", theme.accent, .small);
        y += mh + 12;
    } else if (tagEq(c.tag, "DIRECTIONS")) {
        const sp2 = splitPipe(c.body);
        vt.fillRoundedRect(vt.ctx, tx - 4, y, @max(card_w - 44, 200), 58, 8, theme.surface);
        vt.fillCircle(vt.ctx, tx + 12, y + 14, 4, theme.ok);
        vt.fillRoundedRect(vt.ctx, tx + 11, y + 19, 2, 18, 0, theme.accent);
        vt.fillCircle(vt.ctx, tx + 12, y + 40, 4, theme.accent);
        _ = vt.drawString(vt.ctx, tx + 26, y + 8, sp2.a, theme.text_secondary, .small);
        _ = vt.drawString(vt.ctx, tx + 26, y + 32, sp2.b, theme.text_secondary, .small);
        y += 68;
    } else if (tagEq(c.tag, "IMAGE")) {
        const ih: i32 = 110;
        const iw2 = @max(card_w - 44, 200);
        vt.fillRoundedRect(vt.ctx, tx - 4, y, iw2, ih, 10, theme.surface);
        const icx2 = tx + @divTrunc(iw2, 2);
        const icy2 = y + @divTrunc(ih, 2) - 6;
        vt.fillCircle(vt.ctx, icx2 - 24, icy2 - 14, 10, theme.accent);
        vt.fillRoundedRect(vt.ctx, icx2 - 30, icy2 + 8, 60, 2, 0, theme.ok);
        vt.fillRoundedRect(vt.ctx, icx2 - 22, icy2 + 4, 44, 2, 0, theme.ok);
        _ = vt.drawString(vt.ctx, tx + 8, y + ih - 22, c.body, theme.text_muted, .small);
        y += ih + 10;
    } else if (tagEq(c.tag, "CHART")) {
        const sp2 = splitPipe(c.body);
        const chh: i32 = 100;
        const chw2 = @max(card_w - 44, 200);
        vt.fillRoundedRect(vt.ctx, tx - 4, y, chw2, chh, 8, theme.surface);
        _ = vt.drawString(vt.ctx, tx + 8, y + 6, sp2.a, theme.text_secondary, .small);
        const bar_w2: i32 = @divTrunc(chw2 - 30, 8);
        var bi2: i32 = 0;
        while (bi2 < 8) : (bi2 += 1) {
            const bh2: i32 = 16 + @rem(bi2 * 13 + 5, 50);
            vt.fillRoundedRect(vt.ctx, tx + 10 + bi2 * bar_w2, y + chh - 12 - bh2, bar_w2 - 3, bh2, 3, theme.accent);
        }
        y += chh + 10;
    } else if (tagEq(c.tag, "TABLE")) {
        const tw2 = @max(card_w - 44, 200);
        vt.fillRoundedRect(vt.ctx, tx - 4, y, tw2, 32, 6, theme.surface);
        _ = drawBold(vt, tx + 8, y + 8, c.body, theme.text_primary, .small);
        vt.fillRoundedRect(vt.ctx, tx - 4, y + 30, tw2, 1, 0, theme.border);
        y += 38;
    } else if (tagEq(c.tag, "PROGRESS")) {
        const sp2 = splitPipe(c.body);
        _ = vt.drawString(vt.ctx, tx, y + 2, sp2.a, theme.text_secondary, .small);
        var pct2: i32 = 0;
        for (sp2.b) |pc| {
            if (pc >= '0' and pc <= '9') pct2 = pct2 * 10 + @as(i32, pc - '0');
        }
        if (pct2 > 100) pct2 = 100;
        const pw2 = @max(card_w - 44, 200);
        vt.fillRoundedRect(vt.ctx, tx, y + 22, pw2, 6, 3, theme.surface);
        const fill2: i32 = @divTrunc(pw2 * pct2, 100);
        if (fill2 > 0) vt.fillRoundedRect(vt.ctx, tx, y + 22, fill2, 6, 3, theme.accent);
        y += 36;
    } else if (tagEq(c.tag, "TOGGLE")) {
        const sp2 = splitPipe(c.body);
        _ = vt.drawString(vt.ctx, tx, y + 4, sp2.a, theme.text_secondary, .small);
        const is_on2 = sp2.b.len >= 2 and sp2.b[0] == 'o' and sp2.b[1] == 'n';
        const togx = tx + @max(card_w - 100, 160);
        vt.fillRoundedRect(vt.ctx, togx, y + 2, 40, 20, 10, if (is_on2) theme.ok else theme.surface);
        vt.fillCircle(vt.ctx, togx + (if (is_on2) @as(i32, 28) else @as(i32, 10)), y + 12, 7, theme.text_primary);
        y += 30;
    } else if (tagEq(c.tag, "SLIDER")) {
        const sp2 = splitPipe(c.body);
        _ = vt.drawString(vt.ctx, tx, y + 2, sp2.a, theme.text_secondary, .small);
        var sv2: i32 = 50;
        for (sp2.b) |sc| {
            if (sc >= '0' and sc <= '9') sv2 = sv2 * 10 + @as(i32, sc - '0');
        }
        if (sv2 > 1000) sv2 = @rem(sv2, 101);
        if (sv2 > 100) sv2 = 100;
        const sw3 = @max(card_w - 44, 200);
        vt.fillRoundedRect(vt.ctx, tx, y + 24, sw3, 3, 1, theme.surface);
        const sf2: i32 = @divTrunc(sw3 * sv2, 100);
        if (sf2 > 0) vt.fillRoundedRect(vt.ctx, tx, y + 24, sf2, 3, 1, theme.accent);
        vt.fillCircle(vt.ctx, tx + sf2, y + 25, 6, theme.accent);
        y += 36;
    } else if (tagEq(c.tag, "GRID")) {
        _ = vt.drawString(vt.ctx, tx, y + 2, c.body, theme.text_primary, .small);
        y += 26;
    } else if (tagEq(c.tag, "HEADER")) {
        _ = drawBold(vt, tx, y + 4, c.body, theme.text_primary, .large);
        y += 46;
    } else if (tagEq(c.tag, "BADGE")) {
        const bw2: i32 = @intCast(vt.measureString(vt.ctx, c.body, .small) + 18);
        vt.fillRoundedRect(vt.ctx, tx, y + 2, bw2, 22, 11, theme.accent_dim);
        _ = vt.drawString(vt.ctx, tx + 9, y + 5, c.body, theme.accent, .small);
        y += 32;
    } else if (tagEq(c.tag, "LINK")) {
        const sp2 = splitPipe(c.body);
        _ = vt.drawString(vt.ctx, tx, y + 2, sp2.a, theme.accent, .small);
        if (sp2.b.len > 0) {
            _ = vt.drawString(vt.ctx, tx, y + 20, sp2.b, theme.text_muted, .small);
            y += 38;
        } else y += 24;
    } else if (c.tag.len > 0) {
        const tag_w: i32 = @intCast(vt.measureString(vt.ctx, c.tag, .small));
        _ = vt.drawString(vt.ctx, tx, y + 4, c.tag, theme.accent, .small);
        const body_x = tx + @min(tag_w + 18, 92);
        const used = drawWrappedText(vt, body_x, y + 4, c.body, content_w -| 72, theme.text_secondary);
        y += used + 12;
    } else if (c.body.len > 0) {
        const used = drawWrappedText(vt, tx, y + 2, c.body, content_w, theme.text_secondary);
        y += used + 6;
    }
    return y;
}

/// Draw a full agent card at (x, y): the rounded card background first (the
/// demo's `gl.drawCardRect(..., radius=12, surface)` folded onto
/// `fillRoundedRect`), then each line through `renderLine`. Returns the y after
/// the card (demo `renderAgentCard` returned `draw_y + h + 16`).
pub fn renderCard(vt: *const DrawVTable, theme: *const Theme, text: []const u8, x: i32, draw_y: i32) i32 {
    const bx: i32 = x + 4;
    const card_w: i32 = cardNaturalWidth(vt, text);
    const h = cardHeightForWidth(vt, text, card_w);
    const content_w: u32 = @intCast(@max(card_w - 44, 120));
    // Card background: the one GL primitive (gl.drawCardRect) on the component
    // path, folded onto fillRoundedRect(radius=12).
    vt.fillRoundedRect(vt.ctx, bx, draw_y, card_w, h, 12, theme.surface);
    _ = vt.drawString(vt.ctx, bx + card_w - 28, draw_y + 12, "ai", theme.text_muted, .small);
    const tx = bx + 22;
    var y = draw_y + 14;
    var it: usize = 0;
    while (it < text.len) {
        var e = it;
        while (e < text.len and text[e] != '\n') e += 1;
        const ln = text[it..e];
        it = if (e < text.len) e + 1 else e;
        y = renderLine(vt, theme, ln, bx, tx, y, card_w, content_w);
    }
    return draw_y + h + 16;
}

// ── Hermetic tests (RecordingSurface mock vtable; no framebuffer, no alloc) ──

const Op = enum(u8) { rect, circle, str };
const Call = struct {
    op: Op,
    x: i32 = 0,
    y: i32 = 0,
    w: i32 = 0,
    h: i32 = 0,
    r: i32 = 0,
    color: Color = 0,
    size: Size = .small,
    text_len: usize = 0,
};

const RecordingSurface = struct {
    calls: [256]Call = undefined,
    n: usize = 0,

    fn vtable(self: *RecordingSurface) DrawVTable {
        return .{
            .ctx = @ptrCast(self),
            .fillRoundedRect = recRect,
            .fillCircle = recCircle,
            .drawString = recStr,
            .measureString = recMeasure,
        };
    }

    fn push(self: *RecordingSurface, call: Call) void {
        if (self.n < self.calls.len) {
            self.calls[self.n] = call;
            self.n += 1;
        }
    }

    fn recRect(ctx: *anyopaque, x: i32, y: i32, w: i32, h: i32, radius: i32, color: Color) void {
        const self: *RecordingSurface = @ptrCast(@alignCast(ctx));
        self.push(.{ .op = .rect, .x = x, .y = y, .w = w, .h = h, .r = radius, .color = color });
    }
    fn recCircle(ctx: *anyopaque, cx: i32, cy: i32, r: i32, color: Color) void {
        const self: *RecordingSurface = @ptrCast(@alignCast(ctx));
        self.push(.{ .op = .circle, .x = cx, .y = cy, .r = r, .color = color });
    }
    fn recStr(ctx: *anyopaque, x: i32, y: i32, text: []const u8, color: Color, size: Size) usize {
        const self: *RecordingSurface = @ptrCast(@alignCast(ctx));
        self.push(.{ .op = .str, .x = x, .y = y, .color = color, .size = size, .text_len = text.len });
        return text.len * 7; // deterministic advance
    }
    // measureString must NOT record (it is called from height math too) —
    // deterministic metric: 7px per char.
    fn recMeasure(ctx: *anyopaque, text: []const u8, size: Size) usize {
        _ = ctx;
        _ = size;
        return text.len * 7;
    }

    fn countOp(self: *const RecordingSurface, op: Op) usize {
        var c: usize = 0;
        for (self.calls[0..self.n]) |call| {
            if (call.op == op) c += 1;
        }
        return c;
    }
};

const expect = @import("std").testing.expect;
const expectEqual = @import("std").testing.expectEqual;

fn eq(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (x != y) return false;
    return true;
}

test "ui_dsl parseComponent tag/body split" {
    const tagged = parseComponent("TITLE Hello World");
    try expect(eq(tagged.tag, "TITLE"));
    try expect(eq(tagged.body, "Hello World"));

    const untagged = parseComponent("just some text");
    try expect(eq(untagged.tag, ""));
    try expect(eq(untagged.body, "just some text"));

    // lowercase leading token is not an upper tag → whole line is body.
    const malformed = parseComponent("title lower");
    try expect(eq(malformed.tag, ""));
    try expect(eq(malformed.body, "title lower"));

    // leading/trailing spaces trimmed on the untagged body.
    const spaced = parseComponent("   padded   ");
    try expect(eq(spaced.tag, ""));
    try expect(eq(spaced.body, "padded"));
}

test "ui_dsl splitPipe" {
    const p = splitPipe("name | detail");
    try expect(eq(p.a, "name"));
    try expect(eq(p.b, "detail"));

    const none = splitPipe("no pipe here");
    try expect(eq(none.a, "no pipe here"));
    try expect(eq(none.b, ""));
}

test "ui_dsl componentHeight fixed heights" {
    var surf = RecordingSurface{};
    const vt = surf.vtable();
    try expectEqual(@as(i32, 172), componentHeight(&vt, "MAP tel aviv", 400));
    try expectEqual(@as(i32, 68), componentHeight(&vt, "DIRECTIONS a|b", 400));
    try expectEqual(@as(i32, 110), componentHeight(&vt, "CHART t|x", 400));
    try expectEqual(@as(i32, 44), componentHeight(&vt, "BTN go", 400));
    try expectEqual(@as(i32, 46), componentHeight(&vt, "HEADER hi", 400));
    try expectEqual(@as(i32, 32), componentHeight(&vt, "BADGE new", 400));
    try expectEqual(@as(i32, 36), componentHeight(&vt, "PROGRESS p|50", 400));
    try expectEqual(@as(i32, 30), componentHeight(&vt, "TOGGLE t|on", 400));
    try expectEqual(@as(i32, 36), componentHeight(&vt, "SLIDER s|50", 400));
    try expectEqual(@as(i32, 26), componentHeight(&vt, "GRID g", 400));
    try expectEqual(@as(i32, 120), componentHeight(&vt, "IMAGE pic", 400));
    try expectEqual(@as(i32, 38), componentHeight(&vt, "TABLE head", 400));
}

test "ui_dsl componentHeight computed heights" {
    var surf = RecordingSurface{};
    const vt = surf.vtable();
    // TITLE "Hi" → 1 line * lineHeight(medium=22) + 16 = 38 (fits in width).
    try expectEqual(@as(i32, 38), componentHeight(&vt, "TITLE Hi", 400));
    // TEXT "Hi" → 22 + 10 = 32.
    try expectEqual(@as(i32, 32), componentHeight(&vt, "TEXT Hi", 400));
    // ROW "a|b" → wrapped at small(16) = 16 + 8 = 24.
    try expectEqual(@as(i32, 24), componentHeight(&vt, "ROW a|b", 400));
    // STAT and KV share STAT layout.
    try expectEqual(componentHeight(&vt, "STAT k|v", 400), componentHeight(&vt, "KV k|v", 400));
    // Empty line → 0.
    try expectEqual(@as(i32, 0), componentHeight(&vt, "", 400));
}

test "ui_dsl renderLine PICK emits one rect then two strings" {
    var surf = RecordingSurface{};
    const vt = surf.vtable();
    const theme = demoTheme();
    _ = renderLine(&vt, &theme, "PICK Dana|optics", 0, 22, 0, 400, 356);
    // Expect: fillRoundedRect (pill), then two drawString calls (bold a draws
    // twice via drawBold → 2 str, then b → 1 str = 3 str), rect first.
    try expect(surf.n >= 1);
    try expectEqual(Op.rect, surf.calls[0].op);
    try expect(surf.countOp(.rect) == 1);
    // bold draws a twice + b once = 3 string draws
    try expectEqual(@as(usize, 3), surf.countOp(.str));
}

test "ui_dsl renderLine covers all 20 tags without overrun" {
    const tags = [_][]const u8{
        "TITLE t",         "TEXT t",      "ROW a|b",       "PICK a|b",
        "STAT k|v",        "KV k|v",      "LIST item",     "BTN go",
        "MAP loc",         "DIRECTIONS a|b", "CHART t|x",  "PROGRESS p|50",
        "TOGGLE t|on",     "SLIDER s|50", "GRID g",        "HEADER h",
        "BADGE b",         "LINK t|u",    "IMAGE pic",     "TABLE head",
    };
    const theme = demoTheme();
    inline for (tags) |line| {
        var surf = RecordingSurface{};
        const vt = surf.vtable();
        const next = renderLine(&vt, &theme, line, 0, 22, 0, 400, 356);
        try expect(next >= 0);
        try expect(surf.n > 0); // every tag drew something
    }
}

test "ui_dsl renderCard advances y by cardHeight and draws card bg first" {
    var surf = RecordingSurface{};
    const vt = surf.vtable();
    const theme = demoTheme();
    const text = "TITLE Intro\nTEXT a line\nROW k|v";
    const card_w = cardNaturalWidth(&vt, text);
    const h = cardHeightForWidth(&vt, text, card_w);
    const end_y = renderCard(&vt, &theme, text, 0, 0);
    try expectEqual(h + 16, end_y);
    // First recorded op is the card background rounded rect at radius 12.
    try expectEqual(Op.rect, surf.calls[0].op);
    try expectEqual(@as(i32, 12), surf.calls[0].r);
}

fn demoTheme() Theme {
    return .{
        .bg = 0x18181f,
        .surface = 0x21212a,
        .border = 0x263240,
        .text_primary = 0xf0f0f7,
        .text_secondary = 0xceced8,
        .text_muted = 0x7676_86,
        .accent = 0x7c5cf6,
        .accent_dim = 0x2e2a46,
        .ok = 0x50c878,
    };
}
