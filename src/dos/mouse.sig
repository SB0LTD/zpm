//! A Microsoft mouse driver, int 33h (functions 00h-24h and 26h as
//! programs of the early 1990s use them): reset and status, show/hide
//! and the cursor (09h's graphics masks with its hot spot, 0Ah's text
//! cursor: `overlay` draws it over the finished picture, so it never
//! touches video memory and a program reading the screen back sees its
//! own pixels), position and
//! buttons, presses and releases, ranges, the mickey ratio, motion
//! counters, the user's event handler (0Ch/14h: queued for the machine,
//! which calls it with the event mask in AX: `userCall`, `handlerRegs`),
//! state save/restore, sensitivity, the page, the version.
//!
//! Written from Microsoft's mouse programmer's reference interface as
//! Ralf Brown's Interrupt List documents it; no driver's code.

const std = @import("std");
const regs = @import("regs.sig");
const Regs = regs.Regs;
const Memory = @import("mem.sig").Memory;

/// Events (the handler's mask and AX).
pub const MOVED: u16 = 0x01;
pub const LEFT_DOWN: u16 = 0x02;
pub const LEFT_UP: u16 = 0x04;
pub const RIGHT_DOWN: u16 = 0x08;
pub const RIGHT_UP: u16 = 0x10;
pub const MIDDLE_DOWN: u16 = 0x20;
pub const MIDDLE_UP: u16 = 0x40;

const Button = struct {
    presses: u16 = 0,
    releases: u16 = 0,
    press_x: i16 = 0,
    press_y: i16 = 0,
    release_x: i16 = 0,
    release_y: i16 = 0,
};

/// What 16h/17h save (the driver's whole state but the pending events).
const Saved = struct {
    x: i16,
    y: i16,
    min_x: i16,
    max_x: i16,
    min_y: i16,
    max_y: i16,
    visible: i16,
    hratio: u16,
    vratio: u16,
    mask: u16,
    seg: u16,
    off: u16,
};

/// The default arrow: a white arrow with a black outline.
const DEFAULT_AND = [16]u16{ 0x3FFF, 0x1FFF, 0x0FFF, 0x07FF, 0x03FF, 0x01FF, 0x00FF, 0x007F, 0x003F, 0x001F, 0x01FF, 0x10FF, 0x30FF, 0xF87F, 0xF87F, 0xFC3F };
const DEFAULT_XOR = [16]u16{ 0x0000, 0x4000, 0x6000, 0x7000, 0x7800, 0x7C00, 0x7E00, 0x7F00, 0x7F80, 0x7C00, 0x6C00, 0x4600, 0x0600, 0x0300, 0x0300, 0x0000 };

pub const State = struct {
    /// The position in the driver's virtual screen (640 wide in most
    /// modes), the buttons (bit 0 left, 1 right, 2 middle).
    x: i16 = 320,
    y: i16 = 100,
    held: u3 = 0,
    min_x: i16 = 0,
    max_x: i16 = 639,
    min_y: i16 = 0,
    max_y: i16 = 199,
    /// The cursor shows when this is 0 (it starts at -1: hidden).
    visible: i16 = -1,
    /// Mickeys per 8 pixels.
    hratio: u16 = 8,
    vratio: u16 = 16,
    /// Mickeys not yet turned into pixels (in eighths of a mickey times
    /// the ratio's units).
    rem_x: i32 = 0,
    rem_y: i32 = 0,
    /// Motion since 0Bh last read it.
    mick_x: i16 = 0,
    mick_y: i16 = 0,
    /// Motion since the user handler last ran (its SI, DI).
    hmick_x: i16 = 0,
    hmick_y: i16 = 0,
    btn: [3]Button = [_]Button{.{}} ** 3,
    /// The user handler, its mask, and the events waiting for it.
    mask: u16 = 0,
    seg: u16 = 0,
    off: u16 = 0,
    pending: u16 = 0,
    // Things programs set and read back.
    hot_x: i16 = 0,
    hot_y: i16 = 0,
    text_type: u16 = 0,
    text_and: u16 = 0xFFFF,
    text_xor: u16 = 0x7700,
    /// The graphics cursor (09h): 16 rows of screen (AND) and cursor
    /// (XOR) masks, the leftmost pixel in bit 15; Microsoft's arrow.
    and_mask: [16]u16 = DEFAULT_AND,
    xor_mask: [16]u16 = DEFAULT_XOR,
    threshold: u16 = 64,
    sens: [3]u16 = .{ 50, 50, 50 },
    page: u16 = 0,
    language: u16 = 0,
    enabled: bool = true,

    pub fn reset(self: *State) void {
        self.* = .{};
    }
    /// The host's pointer moved by (dx, dy) in its own pixels, taken as
    /// mickeys.
    pub fn move(self: *State, dx: i32, dy: i32) void {
        if (!self.enabled or (dx == 0 and dy == 0)) return;
        self.mick_x +%= @truncate(dx);
        self.mick_y +%= @truncate(dy);
        self.hmick_x +%= @truncate(dx);
        self.hmick_y +%= @truncate(dy);
        // pixels = mickeys * 8 / ratio, the remainder kept.
        self.rem_x += dx * 8;
        self.rem_y += dy * 8;
        const px = @divTrunc(self.rem_x, @as(i32, @max(self.hratio, 1)));
        const py = @divTrunc(self.rem_y, @as(i32, @max(self.vratio, 1)));
        self.rem_x -= px * @max(self.hratio, 1);
        self.rem_y -= py * @max(self.vratio, 1);
        self.setPos(@as(i32, self.x) + px, @as(i32, self.y) + py);
        self.pending |= MOVED;
    }
    /// The host's buttons (bit 0 left, 1 right, 2 middle).
    pub fn buttons(self: *State, b: u3) void {
        if (!self.enabled) return;
        const was = self.held;
        self.held = b;
        var i: u2 = 0;
        while (i < 3) : (i += 1) {
            const bit = @as(u3, 1) << i;
            if ((was ^ b) & bit == 0) continue;
            const s = &self.btn[i];
            const ev: u16 = @as(u16, 0x02) << (@as(u4, i) * 2);
            if (b & bit != 0) {
                s.presses +%= 1;
                s.press_x = self.x;
                s.press_y = self.y;
                self.pending |= ev;
            } else {
                s.releases +%= 1;
                s.release_x = self.x;
                s.release_y = self.y;
                self.pending |= ev << 1;
            }
        }
    }
    /// A user handler waits to be called: its far address and the event
    /// mask (the machine calls it as int 33h's driver would: a far call
    /// with the registers `handlerRegs` sets, its RETF returning). Taking
    /// it clears the events.
    pub fn userCall(self: *State) ?struct { seg: u16, off: u16, mask: u16 } {
        const ev = self.pending & self.mask;
        if (ev == 0 or (self.seg == 0 and self.off == 0)) {
            if (self.mask == 0) self.pending = 0;
            return null;
        }
        self.pending = 0;
        return .{ .seg = self.seg, .off = self.off, .mask = ev };
    }
    /// The handler's registers: AX the events, BX the buttons, CX and DX
    /// the position, SI and DI the motion in mickeys since its last call.
    pub fn handlerRegs(self: *State, r: *Regs, mask: u16) void {
        r.setAx(mask);
        r.setBx(self.held);
        r.setCx(@bitCast(self.x));
        r.setDx(@bitCast(self.y));
        r.setSi(@bitCast(self.hmick_x));
        r.setDi(@bitCast(self.hmick_y));
        self.hmick_x = 0;
        self.hmick_y = 0;
    }

    fn setPos(self: *State, x: i32, y: i32) void {
        self.x = @intCast(std.math.clamp(x, self.min_x, self.max_x));
        self.y = @intCast(std.math.clamp(y, self.min_y, self.max_y));
    }

    /// The virtual screen of the BIOS's video mode (0x449) and rows (0x484).
    fn fitMode(self: *State, mem: *const Memory) void {
        const mode = mem.rdB(0x40, 0x49) & 0x7F;
        const rows: i16 = @as(i16, mem.rdB(0x40, 0x84)) + 1;
        self.min_x = 0;
        self.min_y = 0;
        self.max_x = 639;
        self.max_y = switch (mode) {
            0x00...0x03, 0x07 => (if (rows >= 25) rows else 25) * 8 - 1,
            0x0F, 0x10 => 349,
            0x11, 0x12 => 479,
            else => 199,
        };
        self.x = @divTrunc(self.max_x + 1, 2);
        self.y = @divTrunc(self.max_y + 1, 2);
    }

    fn save(self: *const State) Saved {
        return .{ .x = self.x, .y = self.y, .min_x = self.min_x, .max_x = self.max_x, .min_y = self.min_y, .max_y = self.max_y, .visible = self.visible, .hratio = self.hratio, .vratio = self.vratio, .mask = self.mask, .seg = self.seg, .off = self.off };
    }
    fn restore(self: *State, s: Saved) void {
        self.x = s.x;
        self.y = s.y;
        self.min_x = s.min_x;
        self.max_x = s.max_x;
        self.min_y = s.min_y;
        self.max_y = s.max_y;
        self.visible = s.visible;
        self.hratio = s.hratio;
        self.vratio = s.vratio;
        self.mask = s.mask;
        self.seg = s.seg;
        self.off = s.off;
    }
};

/// The cursor over the picture the VGA rendered (`out`, `stride` pixels a
/// row, `w` x `h`, XRGB), when the program shows it: in text modes the
/// character cell under it (0Ah's software cursor inverts its colours as
/// the default attribute masks do; the hardware one marks its scan lines),
/// in graphics modes the 16x16 masks at the position less the hot spot,
/// in the mode's own pixels (the driver's virtual screen scaled to it).
pub fn overlay(st: *const State, mem: *const Memory, out: []u32, stride: u32, w: u32, h: u32) void {
    if (st.visible < 0 or !st.enabled or w == 0 or h == 0) return;
    const x: i32 = st.x;
    const y: i32 = st.y;
    if (textMode(mem)) {
        const cols: u32 = @max(mem.rdW(0x40, 0x4A), 1);
        const rows: u32 = @as(u32, mem.rdB(0x40, 0x84)) + 1;
        const cw = w / cols;
        const ch = h / @max(rows, 1);
        if (cw == 0 or ch == 0) return;
        // (the virtual screen is 640 wide whatever the columns, 8 rows a cell)
        const col: u32 = @intCast(@divTrunc(@max(x, 0) * @as(i32, @intCast(cols)), 640));
        const row: u32 = @intCast(@divTrunc(@max(y, 0), 8));
        if (col >= cols or row >= rows) return;
        var first: u32 = 0;
        var last: u32 = ch;
        if (st.text_type == 1) {
            // A hardware cursor: scan lines CX to DX of the cell.
            first = @min(@as(u32, st.text_and & 0x1F) * ch / 16, ch - 1);
            last = @min(@as(u32, st.text_xor & 0x1F) * ch / 16 + 1, ch);
        } else if (st.text_xor & 0xFF00 == 0 and st.text_and & 0xFF00 == 0xFF00) return;
        var yy = row * ch + first;
        while (yy < row * ch + last and yy < h) : (yy += 1) {
            for (out[yy * stride + col * cw ..][0..cw]) |*px| px.* ^= 0x00FF_FFFF;
        }
        return;
    }
    const mode = mem.rdB(0x40, 0x49) & 0x7F;
    // The mode's pixels per virtual pixel: 640 virtual columns; rows as
    // the mode has them (a mode the BIOS table doesn't know: 1:1).
    const vw: i32 = if (mode <= 0x13) 640 else @intCast(w);
    const vh: i32 = switch (mode) {
        0x0F, 0x10 => 350,
        0x11, 0x12 => 480,
        0x04...0x06, 0x0D, 0x0E, 0x13 => 200,
        else => @intCast(h),
    };
    const px0 = @divTrunc(x * @as(i32, @intCast(w)), vw) - st.hot_x;
    const py0 = @divTrunc(y * @as(i32, @intCast(h)), vh) - st.hot_y;
    for (0..16) |ry| {
        const py = py0 + @as(i32, @intCast(ry));
        if (py < 0 or py >= @as(i32, @intCast(h))) continue;
        const am = st.and_mask[ry];
        const xm = st.xor_mask[ry];
        for (0..16) |rx| {
            const pxx = px0 + @as(i32, @intCast(rx));
            if (pxx < 0 or pxx >= @as(i32, @intCast(w))) continue;
            const bit = @as(u16, 0x8000) >> @intCast(rx);
            const p = &out[@as(usize, @intCast(py)) * stride + @as(usize, @intCast(pxx))];
            if (am & bit == 0) p.* &= 0xFF00_0000;
            if (xm & bit != 0) p.* ^= 0x00FF_FFFF;
        }
    }
}

fn textMode(mem: *const Memory) bool {
    return switch (mem.rdB(0x40, 0x49) & 0x7F) {
        0x00...0x03, 0x07 => true,
        else => false,
    };
}

fn s16(v: u16) i16 {
    return @bitCast(v);
}

/// int 33h.
pub fn int33(st: *State, r: *Regs, mem: *Memory) void {
    switch (r.ax()) {
        // Reset (00h) and the software reset (21h): installed, 2 buttons.
        0x00, 0x21 => {
            const lang = st.language;
            const held = st.held;
            st.reset();
            st.language = lang;
            st.held = held;
            st.fitMode(mem);
            r.setAx(0xFFFF);
            r.setBx(2);
        },
        0x01 => {
            if (st.visible < 0) st.visible += 1;
        },
        0x02, 0x10 => st.visible -|= 1,
        0x03 => {
            var x = st.x;
            var y = st.y;
            // (in text modes, the character cell's corner)
            if (textMode(mem)) {
                x &= ~@as(i16, 7);
                y &= ~@as(i16, 7);
            }
            r.setBx(st.held);
            r.setCx(@bitCast(x));
            r.setDx(@bitCast(y));
        },
        0x04 => st.setPos(s16(r.cx()), s16(r.dx())),
        0x05, 0x06 => {
            const presses = r.ax() == 0x05;
            const i = r.bx();
            r.setAx(st.held);
            if (i > 2) {
                r.setBx(0);
                return;
            }
            const b = &st.btn[i];
            if (presses) {
                r.setBx(b.presses);
                r.setCx(@bitCast(b.press_x));
                r.setDx(@bitCast(b.press_y));
                b.presses = 0;
            } else {
                r.setBx(b.releases);
                r.setCx(@bitCast(b.release_x));
                r.setDx(@bitCast(b.release_y));
                b.releases = 0;
            }
        },
        0x07, 0x08 => {
            var lo = s16(r.cx());
            var hi = s16(r.dx());
            if (lo > hi) std.mem.swap(i16, &lo, &hi);
            if (r.ax() == 0x07) {
                st.min_x = lo;
                st.max_x = hi;
            } else {
                st.min_y = lo;
                st.max_y = hi;
            }
            st.setPos(st.x, st.y);
        },
        0x09 => {
            st.hot_x = s16(r.bx());
            st.hot_y = s16(r.cx());
            // ES:DX: 16 words of screen mask, then 16 of cursor mask.
            const at = r.base[regs.ES] +% r.dx();
            for (0..16) |i| {
                st.and_mask[i] = mem.rd16(at +% @as(u32, @intCast(i * 2)));
                st.xor_mask[i] = mem.rd16(at +% @as(u32, @intCast(32 + i * 2)));
            }
        },
        0x0A => {
            st.text_type = r.bx();
            st.text_and = r.cx();
            st.text_xor = r.dx();
        },
        0x0B => {
            r.setCx(@bitCast(st.mick_x));
            r.setDx(@bitCast(st.mick_y));
            st.mick_x = 0;
            st.mick_y = 0;
        },
        0x0C => {
            st.mask = r.cx();
            st.seg = r.seg[regs.ES];
            st.off = r.dx();
            st.pending = 0;
        },
        // Light pen emulation on/off: taken.
        0x0D, 0x0E => {},
        0x0F => {
            st.hratio = @max(r.cx(), 1);
            st.vratio = @max(r.dx(), 1);
        },
        0x13 => st.threshold = r.dx(),
        0x14 => {
            const mask = st.mask;
            const seg = st.seg;
            const off = st.off;
            st.mask = r.cx();
            st.seg = r.seg[regs.ES];
            st.off = r.dx();
            st.pending = 0;
            r.setCx(mask);
            r.setSeg(regs.ES, seg);
            r.setDx(off);
        },
        0x15 => r.setBx(@sizeOf(Saved)),
        0x16 => {
            const s = st.save();
            mem.copyIn(r.base[regs.ES] +% r.dx(), std.mem.asBytes(&s));
        },
        0x17 => {
            var s: Saved = undefined;
            mem.copyOut(r.base[regs.ES] +% r.dx(), std.mem.asBytes(&s));
            st.restore(s);
        },
        // Alternate handlers (18h-19h): none.
        0x18 => r.setAx(0xFFFF),
        0x19 => r.setCx(0),
        0x1A => st.sens = .{ r.bx(), r.cx(), r.dx() },
        0x1B => {
            r.setBx(st.sens[0]);
            r.setCx(st.sens[1]);
            r.setDx(st.sens[2]);
        },
        // Interrupt rate: taken.
        0x1C => {},
        0x1D => st.page = r.bx(),
        0x1E => r.setBx(st.page),
        // Disable: the old int 33h vector (this driver's own).
        0x1F => {
            st.enabled = false;
            r.setAx(0x001F);
            r.setBx(mem.rdW(0, 0x33 * 4));
            r.setSeg(regs.ES, mem.rdW(0, 0x33 * 4 + 2));
        },
        0x20 => {
            st.enabled = true;
            r.setAx(0x0020);
        },
        0x22 => st.language = r.bx(),
        0x23 => r.setBx(st.language),
        // Version 6.26, a PS/2 mouse (no IRQ to report).
        0x24 => {
            r.setBx(0x0626);
            r.setCx(0x0400);
        },
        // The virtual screen's maximum coordinates.
        0x26 => {
            r.setBx(if (st.enabled) 0 else 0xFFFF);
            r.setCx(@bitCast(st.max_x));
            r.setDx(@bitCast(st.max_y));
        },
        else => {},
    }
}

test {
    _ = @import("mouse_test.sig");
    std.testing.refAllDecls(@This());
}
