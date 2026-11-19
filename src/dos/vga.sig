//! The VGA: 256 KiB in four planes, the sequencer, CRT controller,
//! graphics controller, attribute controller, DAC (256 colours of 18
//! bits) and the miscellaneous/status registers at 0x3B0-0x3DF; memory at
//! 0xA0000-0xBFFFF as the graphics controller maps it (read modes 0-1,
//! write modes 0-3, latches, chain-4, odd/even). It shows text modes
//! (with the font the BIOS put in plane 2), CGA/EGA/VGA graphics modes,
//! mode 13h and the unchained ("mode X") 256-colour modes, with the
//! CRTC's start address, line compare (split screen), pixel panning and
//! double scanning; the status register's retraces follow emulated time
//! (the CRTC's own timing: 70 Hz for 400 lines, 60 Hz for 480).
//!
//! SVGA: `svga` (vesa.sig) is the card's 4 MiB frame buffer and VESA
//! mode. While one is set, render shows it (8 bits through this DAC, or
//! direct colour) and the machine sends window A and the linear frame
//! buffer to it; the VGA's registers, DAC and retrace stay as they are.
//! The DAC is 6 bits a component, or 8 after VBE's 4F08 (`dac8`).
//!
//! Clean room, from IBM's VGA technical reference and the FreeVGA
//! project's register descriptions.
//!
//! Memory: `vram[a]` holds the four planes' bytes at plane address `a`
//! (plane p in byte p), so a latch load is one read. The CPU reaches it
//! as the memory map select, chain-4 (plane = address bits 0-1, the
//! plane address with them cleared) and odd/even (plane = bit 0, the
//! plane address with it cleared) say. The CRTC scans it by its memory
//! address counter in byte, word or doubleword mode, so the same picture
//! comes out however a program set the registers up.
//!
//! Time: the machine calls `advance(us)` before it runs the CPU for those
//! microseconds; while the CPU runs, each read of input status 1 moves
//! the time it sees on a little (`POLL_NS`), up to the slice's end, so a
//! program that waits for the two-line vertical retrace sees it. The
//! start address is latched as retrace starts; at the first displayed
//! line the frame is taken (the planes, that start, the panning), and
//! render shows that frame. So a program that sets the start during
//! display and the panning during retrace gets the pair it meant, and a
//! double-buffered one is shown whole whenever the host asks.

const std = @import("std");
const vesa = @import("vesa.sig");

pub const Size = vesa.Size;

/// Bytes in each plane.
pub const PLANE: u32 = 0x10000;
/// How far one read of input status 1 moves the time the CPU sees.
pub const POLL_NS: u32 = 1000;
/// The widest line render makes (256 characters of 9 dots, and panning).
const MAX_LINE: u32 = 2400;

/// Each bit of a nibble to a whole byte: plane mask -> 32-bit mask.
pub const expand4: [16]u32 = blk: {
    var t: [16]u32 = undefined;
    for (0..16) |i| {
        var v: u32 = 0;
        for (0..4) |p| {
            if (i & (1 << p) != 0) v |= @as(u32, 0xFF) << (8 * p);
        }
        t[i] = v;
    }
    break :blk t;
};

/// A byte's eight bits as eight bytes of 0/1, the leftmost pixel first.
const spread: [256]u64 = blk: {
    @setEvalBranchQuota(10000);
    var t: [256]u64 = undefined;
    for (0..256) |b| {
        var v: u64 = 0;
        for (0..8) |i| {
            if (b & (0x80 >> i) != 0) v |= @as(u64, 1) << (8 * i);
        }
        t[b] = v;
    }
    break :blk t;
};

/// A CGA byte's four 2-bit pixels as four bytes, the leftmost first.
const cga4: [256]u32 = blk: {
    @setEvalBranchQuota(10000);
    var t: [256]u32 = undefined;
    for (0..256) |b| {
        var v: u32 = 0;
        for (0..4) |i| v |= @as(u32, (b >> (6 - 2 * i)) & 3) << (8 * i);
        t[b] = v;
    }
    break :blk t;
};

/// What the CRTC's address counter means (CRTC 14h and 17h).
const AddrMode = struct {
    dw: bool,
    word: bool,
    aw15: bool,
    cms: bool,
    srs: bool,
};

inline fn xlate(ma0: u32, rs: u32, am: AddrMode) u32 {
    const ma = ma0 & 0xFFFF;
    var a: u32 = ma;
    if (am.dw) {
        a = (ma << 2) | ((ma >> 14) & 3);
    } else if (am.word) {
        a = (ma << 1) | ((ma >> (if (am.aw15) 15 else 13)) & 1);
    }
    if (am.cms) a = (a & ~@as(u32, 0x2000)) | ((rs & 1) << 13);
    if (am.srs) a = (a & ~@as(u32, 0x4000)) | (((rs >> 1) & 1) << 14);
    return a & 0xFFFF;
}

/// A 6-bit DAC entry as XRGB8888.
inline fn rgb6(r: u8, g: u8, b: u8) u32 {
    const e = struct {
        fn f(c: u8) u32 {
            const c6: u32 = c & 0x3F;
            return (c6 << 2) | (c6 >> 4);
        }
    }.f;
    return (e(r) << 16) | (e(g) << 8) | e(b);
}
inline fn rgb8(r: u8, g: u8, b: u8) u32 {
    return (@as(u32, r) << 16) | (@as(u32, g) << 8) | b;
}

/// The CRTC's timing in nanoseconds and lines.
pub const Timing = struct {
    line_ns: u32 = 31_778,
    hde_ns: u32 = 25_422,
    lines: u32 = 449,
    vde: u32 = 400,
    vrs: u32 = 412,
    vre: u32 = 414,
    frame_ns: u64 = 31_778 * 449,
};

pub const Vga = struct {
    /// The four planes (see the header).
    vram: [PLANE]u32 = undefined,
    latch: u32 = 0,

    misc: u8 = 0,
    fcr: u8 = 0,
    seq_i: u8 = 0,
    seq: [8]u8 = @splat(0),
    crtc_i: u8 = 0,
    crtc: [0x19]u8 = @splat(0),
    gc_i: u8 = 0,
    gc: [9]u8 = @splat(0),
    /// The attribute controller's index (bit 5: palette address source)
    /// and whether 0x3C0's next write is data.
    ac_i: u8 = 0,
    ac_data: bool = false,
    ac: [0x15]u8 = @splat(0),

    /// The DAC: 6-bit components (8-bit with `dac8`), and each entry as
    /// XRGB8888.
    dac: [256][3]u8 = @splat(.{ 0, 0, 0 }),
    dac8: bool = false,
    dac_rgb: [256]u32 = @splat(0),
    dac_mask: u8 = 0xFF,
    dac_w: u8 = 0,
    dac_wc: u8 = 0,
    dac_r: u8 = 0,
    dac_rc: u8 = 0,
    dac_buf: [3]u8 = .{ 0, 0, 0 },
    /// 0x3C7's answer: 3 after a read index was set, 0 after a write one.
    dac_state: u8 = 0,

    /// Graphics controller writes need nothing but the map mask (write
    /// mode 0, no rotation, no set/reset, replace, bit mask FFh).
    plain: bool = true,

    // Time.
    t_ns: u64 = 0,
    slice_ns: u32 = 0,
    poll_ns: u32 = 0,
    timing_dirty: bool = true,
    tm: Timing = .{},
    frame_flag: bool = false,
    /// Retraces since reset (the cursor's and text blink's clock).
    frames: u32 = 0,
    start_latch: u16 = 0,
    latched: bool = false,
    /// The frame on show, taken at its first line: the planes, its start
    /// address and panning (render shows it once time runs).
    snap: [PLANE]u32 = undefined,
    shown_start: u16 = 0,
    shown_pan: u8 = 0,
    shown: bool = false,

    // Render's scratch.
    line: [MAX_LINE]u8 = undefined,
    lut: [256]u32 = undefined,

    /// The SVGA's memory and VESA mode (see the header).
    svga: vesa.Svga = .{},

    pub fn reset(self: *Vga) void {
        // (field by field: the planes, their snapshot and the SVGA's memory
        // are cleared here, not copied from a default kept in the file)
        vesa.resetFields(Vga, self);
        const info = @typeInfo(Vga).@"struct";
        inline for (info.field_names, info.field_types) |name, FT| {
            if (comptime @sizeOf(FT) > 4096 and FT != vesa.Svga) @memset(std.mem.asBytes(&@field(self, name)), 0);
        }
        self.svga.reset();
    }

    // ── Time ─────────────────────────────────────────────────────────────

    /// Emulated time goes on (retrace in the status register).
    pub fn advance(self: *Vga, us: u32) void {
        const g = self.timing();
        const old = self.t_ns;
        const d: u64 = @as(u64, us) * 1000;
        self.t_ns = old + d;
        self.slice_ns = @intCast(@min(d, 0xFFFF_FFFF));
        self.poll_ns = 0;
        if (crossed(old, self.t_ns, g.frame_ns, @as(u64, g.vrs) * g.line_ns)) {
            self.frame_flag = true;
            self.frames +%= 1;
            self.start_latch = self.startAddr();
            self.latched = true;
        }
        if (self.latched and crossed(old, self.t_ns, g.frame_ns, 0)) {
            @memcpy(&self.snap, &self.vram);
            self.shown_start = self.start_latch;
            self.shown_pan = self.ac[0x13];
            self.shown = true;
        }
    }

    /// An event at k*p + off (off < p) between a (exclusive) and b.
    fn crossed(a: u64, b: u64, p: u64, off: u64) bool {
        if (b - a >= p) return true;
        return (a + p - off) / p != (b + p - off) / p;
    }

    /// True at the start of each vertical retrace since the last call
    /// (the machine's frame boundary).
    pub fn frameDone(self: *Vga) bool {
        const f = self.frame_flag;
        self.frame_flag = false;
        return f;
    }

    /// The CRTC's timing (from its registers, the dot clock and the
    /// character width).
    pub fn timing(self: *Vga) Timing {
        if (!self.timing_dirty) return self.tm;
        self.timing_dirty = false;
        const c = &self.crtc;
        const clock: u64 = if ((self.misc >> 2) & 3 == 1) 28_322_000 else 25_175_000;
        const cw: u64 = if (self.seq[1] & 1 != 0) 8 else 9;
        const div: u64 = if (self.seq[1] & 8 != 0) 2 else 1;
        const htotal: u64 = @max(@as(u64, c[0]) + 5, 10);
        const hde: u64 = @min(@as(u64, c[1]) + 1, htotal);
        var g: Timing = .{};
        g.line_ns = @intCast(htotal * cw * div * 1_000_000_000 / clock);
        g.hde_ns = @intCast(hde * cw * div * 1_000_000_000 / clock);
        const o = c[7];
        const vt: u32 = @as(u32, c[6]) | (@as(u32, o & 1) << 8) | (@as(u32, (o >> 5) & 1) << 9);
        g.lines = @max(vt + 2, 4);
        g.vde = @min(self.vde(), g.lines);
        var vrs: u32 = @as(u32, c[0x10]) | (@as(u32, (o >> 2) & 1) << 8) | (@as(u32, (o >> 7) & 1) << 9);
        if (vrs >= g.lines) vrs = @min(g.vde, g.lines - 1);
        g.vrs = vrs;
        var len: u32 = ((@as(u32, c[0x11]) & 0xF) -% vrs) & 0xF;
        if (len == 0) len = 16;
        g.vre = vrs + len;
        g.frame_ns = @as(u64, g.line_ns) * g.lines;
        self.tm = g;
        return g;
    }

    fn vde(self: *const Vga) u32 {
        const o = self.crtc[7];
        return (@as(u32, self.crtc[0x12]) | (@as(u32, (o >> 1) & 1) << 8) | (@as(u32, (o >> 6) & 1) << 9)) + 1;
    }
    fn lineCompare(self: *const Vga) u32 {
        return @as(u32, self.crtc[0x18]) | (@as(u32, (self.crtc[7] >> 4) & 1) << 8) | (@as(u32, (self.crtc[9] >> 6) & 1) << 9);
    }
    pub fn startAddr(self: *const Vga) u16 {
        return (@as(u16, self.crtc[0x0C]) << 8) | self.crtc[0x0D];
    }
    pub fn cursorAddr(self: *const Vga) u16 {
        return (@as(u16, self.crtc[0x0E]) << 8) | self.crtc[0x0F];
    }

    /// Input status 1: bit 0 display disabled (blanking), bit 3 vertical
    /// retrace. Reading it resets the attribute controller's flip-flop.
    fn status1(self: *Vga) u8 {
        self.ac_data = false;
        const g = self.timing();
        self.poll_ns = @min(self.poll_ns +| POLL_NS, self.slice_ns);
        const vis = self.t_ns - self.slice_ns + self.poll_ns;
        const pos = vis % g.frame_ns;
        const ln: u64 = pos / g.line_ns;
        const x: u64 = pos % g.line_ns;
        var v: u8 = 0;
        if (ln >= g.vde or x >= g.hde_ns) v |= 0x01;
        if (ln >= g.vrs and ln < g.vre) v |= 0x08;
        return v;
    }

    // ── Memory ───────────────────────────────────────────────────────────

    /// `off` (from 0xA0000) inside the memory map select's window.
    inline fn window(self: *const Vga, off: u32) ?u32 {
        return switch ((self.gc[6] >> 2) & 3) {
            0 => off & 0x1FFFF,
            1 => if (off < 0x10000) off else null,
            2 => if (off >= 0x10000 and off < 0x18000) off - 0x10000 else null,
            else => if (off >= 0x18000 and off < 0x20000) off - 0x18000 else null,
        };
    }

    /// A read or write at 0xA0000 + `off` (off < 0x20000).
    pub fn read(self: *Vga, off: u32) u8 {
        const a = self.window(off) orelse return 0xFF;
        var plane: u5 = undefined;
        var pa: u32 = undefined;
        if (self.seq[4] & 0x08 != 0) {
            plane = @intCast(a & 3);
            pa = a & ~@as(u32, 3);
        } else if (self.gc[5] & 0x10 != 0) {
            plane = @intCast((self.gc[4] & 2) | (a & 1));
            pa = a & ~@as(u32, 1);
        } else {
            plane = @intCast(self.gc[4] & 3);
            pa = a;
        }
        const l = self.vram[pa & 0xFFFF];
        self.latch = l;
        if (self.gc[5] & 0x08 == 0) return @truncate(l >> (plane * 8));
        // Read mode 1: a bit is 1 where every plane the colour don't care
        // register keeps matches the colour compare register.
        const care = expand4[self.gc[7] & 0xF];
        const diff = (l ^ expand4[self.gc[2] & 0xF]) & care;
        const d = diff | (diff >> 8) | (diff >> 16) | (diff >> 24);
        return ~@as(u8, @truncate(d));
    }

    pub fn write(self: *Vga, off: u32, v: u8) void {
        const a = self.window(off) orelse return;
        var mask: u32 = self.seq[2] & 0xF;
        var pa: u32 = undefined;
        if (self.seq[4] & 0x08 != 0) {
            mask &= @as(u32, 1) << @intCast(a & 3);
            pa = a & ~@as(u32, 3);
        } else if (self.seq[4] & 0x04 == 0) {
            mask &= if (a & 1 != 0) 0xA else 0x5;
            pa = a & ~@as(u32, 1);
        } else {
            pa = a;
        }
        pa &= 0xFFFF;
        if (mask == 0) return;
        const m32 = expand4[mask];
        const old = self.vram[pa];
        if (self.plain) {
            self.vram[pa] = (old & ~m32) | ((@as(u32, v) * 0x01010101) & m32);
            return;
        }
        const l = self.latch;
        const rot: u3 = @intCast(self.gc[3] & 7);
        var d: u32 = undefined;
        var bm: u32 = @as(u32, self.gc[8]) * 0x01010101;
        switch (self.gc[5] & 3) {
            0 => {
                const esr = expand4[self.gc[1] & 0xF];
                d = (@as(u32, std.math.rotr(u8, v, rot)) * 0x01010101 & ~esr) | (expand4[self.gc[0] & 0xF] & esr);
                d = self.alu(d, l);
            },
            1 => {
                self.vram[pa] = (old & ~m32) | (l & m32);
                return;
            },
            2 => d = self.alu(expand4[v & 0xF], l),
            else => {
                bm = @as(u32, std.math.rotr(u8, v, rot) & self.gc[8]) * 0x01010101;
                d = self.alu(expand4[self.gc[0] & 0xF], l);
            },
        }
        d = (d & bm) | (l & ~bm);
        self.vram[pa] = (old & ~m32) | (d & m32);
    }

    inline fn alu(self: *const Vga, d: u32, l: u32) u32 {
        return switch ((self.gc[3] >> 3) & 3) {
            0 => d,
            1 => d & l,
            2 => d | l,
            else => d ^ l,
        };
    }

    fn updatePlain(self: *Vga) void {
        self.plain = self.gc[5] & 3 == 0 and self.gc[3] == 0 and self.gc[1] & 0xF == 0 and self.gc[8] == 0xFF;
    }

    /// The registers were set directly (the video BIOS): the timing and
    /// the write path follow them; `mode`: a new mode, so the picture
    /// takes its scroll from the registers until the next frame's.
    pub fn changed(self: *Vga, mode: bool) void {
        self.timing_dirty = true;
        self.updatePlain();
        if (mode) {
            self.shown = false;
            self.latched = false;
        }
    }

    // ── Ports ────────────────────────────────────────────────────────────

    inline fn colour(self: *const Vga) bool {
        return self.misc & 1 != 0;
    }

    pub fn in8(self: *Vga, port: u16) u8 {
        return switch (port) {
            0x3B4 => if (!self.colour()) self.crtc_i else 0xFF,
            0x3B5 => if (!self.colour()) self.crtcRead() else 0xFF,
            0x3BA => if (!self.colour()) self.status1() else 0xFF,
            0x3D4 => if (self.colour()) self.crtc_i else 0xFF,
            0x3D5 => if (self.colour()) self.crtcRead() else 0xFF,
            0x3DA => if (self.colour()) self.status1() else 0xFF,
            0x3C0 => self.ac_i,
            0x3C1 => if (self.ac_i & 0x1F < self.ac.len) self.ac[self.ac_i & 0x1F] else 0,
            // Input status 0: the monitor's sense line says colour.
            0x3C2 => 0x10,
            0x3C3 => 0x01,
            0x3C4 => self.seq_i,
            0x3C5 => if (self.seq_i < 5) self.seq[self.seq_i] else 0,
            0x3C6 => self.dac_mask,
            0x3C7 => self.dac_state,
            0x3C8 => self.dac_w,
            0x3C9 => self.dacRead(),
            0x3CA => self.fcr,
            0x3CC => self.misc,
            0x3CE => self.gc_i,
            0x3CF => if (self.gc_i < self.gc.len) self.gc[self.gc_i] else 0,
            else => 0xFF,
        };
    }

    pub fn out8(self: *Vga, port: u16, v: u8) void {
        switch (port) {
            0x3B4 => if (!self.colour()) {
                self.crtc_i = v;
            },
            0x3B5 => if (!self.colour()) self.crtcWrite(v),
            0x3BA => if (!self.colour()) {
                self.fcr = v;
            },
            0x3D4 => if (self.colour()) {
                self.crtc_i = v;
            },
            0x3D5 => if (self.colour()) self.crtcWrite(v),
            0x3DA => if (self.colour()) {
                self.fcr = v;
            },
            0x3C0 => if (!self.ac_data) {
                self.ac_i = v & 0x3F;
                self.ac_data = true;
            } else {
                self.acWrite(self.ac_i & 0x1F, v);
                self.ac_data = false;
            },
            0x3C2 => {
                self.misc = v;
                self.timing_dirty = true;
            },
            0x3C4 => self.seq_i = v,
            0x3C5 => if (self.seq_i < 5) {
                self.seq[self.seq_i] = v;
                if (self.seq_i == 1) self.timing_dirty = true;
            },
            0x3C6 => self.dac_mask = v,
            0x3C7 => {
                self.dac_r = v;
                self.dac_rc = 0;
                self.dac_w = v +% 1;
                self.dac_state = 3;
            },
            0x3C8 => {
                self.dac_w = v;
                self.dac_wc = 0;
                self.dac_state = 0;
            },
            0x3C9 => self.dacWrite(v),
            0x3CE => self.gc_i = v,
            0x3CF => if (self.gc_i < self.gc.len) {
                self.gc[self.gc_i] = v;
                self.updatePlain();
            },
            else => {},
        }
    }

    fn crtcRead(self: *const Vga) u8 {
        return if (self.crtc_i < self.crtc.len) self.crtc[self.crtc_i] else 0;
    }

    fn crtcWrite(self: *Vga, v: u8) void {
        const i = self.crtc_i;
        if (i >= self.crtc.len) return;
        // The protect bit (11h bit 7) locks 00h-07h, all but 07h's bit 4
        // (line compare's bit 8).
        if (i <= 7 and self.crtc[0x11] & 0x80 != 0) {
            if (i == 7) self.crtc[7] = (self.crtc[7] & ~@as(u8, 0x10)) | (v & 0x10);
            return;
        }
        self.crtc[i] = v;
        self.timing_dirty = true;
    }

    /// An attribute controller register, as 0x3C0's data write sets it.
    pub fn acWrite(self: *Vga, i: u8, v: u8) void {
        if (i >= self.ac.len) return;
        self.ac[i] = switch (i) {
            0x00...0x0F, 0x12 => v & 0x3F,
            0x13, 0x14 => v & 0x0F,
            else => v,
        };
    }

    /// A DAC entry (6-bit components, or 8-bit with `dac8`).
    pub fn setDac(self: *Vga, i: u8, r: u8, g: u8, b: u8) void {
        if (self.dac8) {
            self.dac[i] = .{ r, g, b };
            self.dac_rgb[i] = rgb8(r, g, b);
        } else {
            self.dac[i] = .{ r & 0x3F, g & 0x3F, b & 0x3F };
            self.dac_rgb[i] = rgb6(r, g, b);
        }
    }

    /// The DAC's width: 6 or 8 bits a component. The colours stay as they
    /// look (each entry scaled to the new width).
    pub fn setDacWidth(self: *Vga, eight: bool) void {
        if (eight == self.dac8) return;
        self.dac8 = eight;
        for (&self.dac, 0..) |*c, i| {
            for (c) |*x| x.* = if (eight) (x.* << 2) | (x.* >> 4) else x.* >> 2;
            self.setDac(@intCast(i), c[0], c[1], c[2]);
        }
    }

    fn dacWrite(self: *Vga, v: u8) void {
        self.dac_buf[self.dac_wc] = if (self.dac8) v else v & 0x3F;
        self.dac_wc += 1;
        if (self.dac_wc == 3) {
            self.setDac(self.dac_w, self.dac_buf[0], self.dac_buf[1], self.dac_buf[2]);
            self.dac_w +%= 1;
            self.dac_wc = 0;
        }
    }

    fn dacRead(self: *Vga) u8 {
        const v = self.dac[self.dac_r][self.dac_rc];
        self.dac_rc += 1;
        if (self.dac_rc == 3) {
            self.dac_rc = 0;
            self.dac_r +%= 1;
        }
        return v;
    }

    // ── The picture ──────────────────────────────────────────────────────

    /// The size `render` makes now (before clipping).
    pub fn displaySize(self: *const Vga) Size {
        if (self.svga.active) return self.svga.displaySize();
        const graphics = self.ac[0x10] & 1 != 0;
        const hde: u32 = @as(u32, self.crtc[1]) + 1;
        const w: u32 = if (!graphics)
            hde * @as(u32, if (self.seq[1] & 1 != 0) 8 else 9)
        else if (self.ac[0x10] & 0x40 != 0) hde * 4 else hde * 8;
        return .{ .w = @intCast(@min(w, MAX_LINE - 32)), .h = @intCast(self.vde() / self.lineRep()) };
    }

    /// Scan lines per output line: double scanning, and in graphics the
    /// rows of a character row that show the same memory.
    fn lineRep(self: *const Vga) u32 {
        var rep: u32 = if (self.crtc[9] & 0x80 != 0) 2 else 1;
        const graphics = self.ac[0x10] & 1 != 0;
        if (graphics and self.crtc[0x17] & 3 == 3) rep *= @as(u32, self.crtc[9] & 0x1F) + 1;
        return rep;
    }

    /// The picture as the monitor would show it, XRGB8888 into `out`
    /// (`stride` pixels a row, at most `max.w` x `max.h`): its size, before
    /// any aspect correction (320x200 for mode 13h, 720x400 for text).
    pub fn render(self: *Vga, out: []u32, stride: u32, max: Size) Size {
        if (self.svga.active) return self.renderSvga(out, stride, max);
        const full = self.displaySize();
        if (stride == 0) return .{};
        const w: u32 = @min(@min(full.w, max.w), stride);
        const h: u32 = @min(@min(full.h, max.h), @as(u32, @intCast(out.len / stride)));
        if (w == 0 or h == 0) return .{ .w = @intCast(w), .h = @intCast(h) };

        // The screen is off (clocking mode bit 5) or the palette is being
        // loaded (attribute index bit 5 clear): black.
        if (self.seq[1] & 0x20 != 0 or self.ac_i & 0x20 == 0) {
            var y: u32 = 0;
            while (y < h) : (y += 1) @memset(out[y * stride ..][0..w], 0);
            return .{ .w = @intCast(w), .h = @intCast(h) };
        }

        const graphics = self.ac[0x10] & 1 != 0;
        const m8 = graphics and self.ac[0x10] & 0x40 != 0;
        self.buildLut(m8);

        const c = &self.crtc;
        const am: AddrMode = .{
            .dw = c[0x14] & 0x40 != 0,
            .word = c[0x17] & 0x40 == 0,
            .aw15 = c[0x17] & 0x20 != 0,
            .cms = c[0x17] & 0x01 == 0,
            .srs = c[0x17] & 0x02 == 0,
        };
        const csh: u5 = if (c[0x14] & 0x20 != 0) 2 else if (c[0x17] & 0x08 != 0) 1 else 0;
        const ds = c[9] & 0x80 != 0;
        const msl: u32 = c[9] & 0x1F;
        const rep = self.lineRep();
        const vd = self.vde();
        const lc = self.lineCompare();
        const off2: u32 = @as(u32, c[0x13]) * 2;
        const bytepan: u32 = (c[8] >> 5) & 3;
        const vr: *const [PLANE]u32 = if (self.shown) &self.snap else &self.vram;
        const start: u32 = if (self.shown) self.shown_start else self.startAddr();
        const pan_reg: u8 = (if (self.shown) self.shown_pan else self.ac[0x13]) & 0xF;
        const nine = !graphics and self.seq[1] & 1 == 0;
        var shift: u32 = if (m8)
            (pan_reg >> 1) & 3
        else if (nine)
            (if (pan_reg >= 8) 0 else @as(u32, pan_reg) + 1)
        else
            pan_reg & 7;
        const kind: u8 = if (!graphics) 0 else if (m8 or self.gc[5] & 0x40 != 0) 3 else if (self.gc[5] & 0x20 != 0) 2 else 1;
        const px_per_cc: u32 = switch (kind) {
            0 => if (nine) 9 else 8,
            3 => 4,
            else => 8,
        };
        // Characters to fetch: the width and one more for the panning.
        const ncc: u32 = @min((w + shift + px_per_cc - 1) / px_per_cc, (MAX_LINE - 16) / px_per_cc);

        var ma_row: u32 = start;
        var rs: u32 = c[8] & 0x1F;
        var dph: bool = false;
        var y: u32 = 0;
        var ln: u32 = 0;
        while (ln < vd and y < h) : (ln += 1) {
            if (ln % rep == 0) {
                const ma = ma_row + bytepan;
                switch (kind) {
                    0 => self.textLine(vr, ma, rs, ncc, am, nine),
                    1 => self.planarLine(vr, ma, rs, ncc, am, csh),
                    2 => self.cgaLine(vr, ma, rs, ncc, am, csh),
                    else => self.line256(vr, ma, rs, ncc, am, csh),
                }
                const dst = out[y * stride ..][0..w];
                const src = self.line[shift..][0..w];
                for (dst, src) |*d, s| d.* = self.lut[s];
                y += 1;
            }
            if (ln == lc) {
                // The split screen: the rest from address 0, row scan 0,
                // and (pixel panning mode) no panning.
                ma_row = 0;
                rs = 0;
                dph = false;
                if (self.ac[0x10] & 0x20 != 0) shift = 0;
                continue;
            }
            if (ds) {
                dph = !dph;
                if (dph) continue;
            }
            if (rs >= msl) {
                rs = 0;
                ma_row += off2;
            } else rs += 1;
        }
        return .{ .w = @intCast(w), .h = @intCast(y) };
    }

    /// A VESA mode's picture (its own size, up to 1600x1200): 8 bits
    /// through the DAC and its mask; black while the screen is off.
    fn renderSvga(self: *Vga, out: []u32, stride: u32, max: Size) Size {
        for (0..256) |v| self.lut[v] = self.dac_rgb[v & self.dac_mask];
        const sz = self.svga.render(&self.lut, out, stride, max);
        if (self.seq[1] & 0x20 != 0) {
            var y: u32 = 0;
            while (y < sz.h) : (y += 1) @memset(out[y * stride ..][0..sz.w], 0);
        }
        return sz;
    }

    /// The colours: attribute palette (colour plane enable, colour select),
    /// DAC mask, DAC; for 8-bit mode each nibble through the palette.
    fn buildLut(self: *Vga, m8: bool) void {
        const cpe = self.ac[0x12] & 0xF;
        const p54 = self.ac[0x10] & 0x80 != 0;
        const cs = self.ac[0x14];
        if (m8) {
            var ident = cpe == 0xF;
            for (0..16) |i| {
                if (self.ac[i] & 0xF != i) ident = false;
            }
            for (0..256) |v| {
                const idx: u8 = if (ident) @intCast(v) else (((self.ac[(v >> 4) & cpe] & 0xF) << 4) | (self.ac[v & cpe] & 0xF));
                self.lut[v] = self.dac_rgb[idx & self.dac_mask];
            }
            return;
        }
        for (0..16) |i| {
            const p = self.ac[i & cpe];
            var idx: u8 = if (p54) (p & 0x0F) | ((cs & 3) << 4) else p & 0x3F;
            idx |= (cs & 0x0C) << 4;
            self.lut[i] = self.dac_rgb[idx & self.dac_mask];
        }
    }

    fn line256(self: *Vga, vr: *const [PLANE]u32, ma: u32, rs: u32, n: u32, am: AddrMode, csh: u5) void {
        var cc: u32 = 0;
        while (cc < n) : (cc += 1) {
            const wv = vr[xlate(ma + (cc >> csh), rs, am)];
            std.mem.writeInt(u32, self.line[cc * 4 ..][0..4], wv, .little);
        }
    }

    fn planarLine(self: *Vga, vr: *const [PLANE]u32, ma: u32, rs: u32, n: u32, am: AddrMode, csh: u5) void {
        var cc: u32 = 0;
        while (cc < n) : (cc += 1) {
            const wv = vr[xlate(ma + (cc >> csh), rs, am)];
            const px = spread[wv & 0xFF] | (spread[(wv >> 8) & 0xFF] << 1) |
                (spread[(wv >> 16) & 0xFF] << 2) | (spread[wv >> 24] << 3);
            std.mem.writeInt(u64, self.line[cc * 8 ..][0..8], px, .little);
        }
    }

    fn cgaLine(self: *Vga, vr: *const [PLANE]u32, ma: u32, rs: u32, n: u32, am: AddrMode, csh: u5) void {
        var cc: u32 = 0;
        while (cc < n) : (cc += 1) {
            const wv = vr[xlate(ma + (cc >> csh), rs, am)];
            const lo = cga4[wv & 0xFF] | (cga4[(wv >> 16) & 0xFF] << 2);
            const hi = cga4[(wv >> 8) & 0xFF] | (cga4[wv >> 24] << 2);
            std.mem.writeInt(u32, self.line[cc * 8 ..][0..4], lo, .little);
            std.mem.writeInt(u32, self.line[cc * 8 + 4 ..][0..4], hi, .little);
        }
    }

    fn textLine(self: *Vga, vr: *const [PLANE]u32, ma: u32, rs: u32, n: u32, am: AddrMode, nine: bool) void {
        const c = &self.crtc;
        const cw: u32 = if (nine) 9 else 8;
        const blink = self.ac[0x10] & 0x08 != 0;
        const blink_off = (self.frames >> 4) & 1 != 0;
        const lge = self.ac[0x10] & 0x04 != 0;
        const ul: u32 = c[0x14] & 0x1F;
        const cs: u32 = c[0x0A] & 0x1F;
        const ce: u32 = c[0x0B] & 0x1F;
        const cur_on = c[0x0A] & 0x20 == 0 and rs >= cs and rs <= ce and (self.frames >> 3) & 1 == 0;
        const cur: u32 = @as(u32, self.cursorAddr()) + ((c[0x0B] >> 5) & 3);
        // Character maps A (attribute bit 3 set) and B.
        const sm = self.seq[3];
        const map_a: u32 = (((sm >> 5) & 1) << 2) | ((sm >> 2) & 3);
        const map_b: u32 = (((sm >> 4) & 1) << 2) | (sm & 3);
        const base_a = (map_a & 3) * 0x4000 + (map_a >> 2) * 0x2000;
        const base_b = (map_b & 3) * 0x4000 + (map_b >> 2) * 0x2000;
        var cc: u32 = 0;
        while (cc < n) : (cc += 1) {
            const m = ma + cc;
            const wv = vr[xlate(m, rs, am)];
            const ch: u32 = wv & 0xFF;
            const at: u32 = (wv >> 8) & 0xFF;
            const base = if (at & 0x08 != 0) base_a else base_b;
            var bits: u32 = (vr[(base + ch * 32 + rs) & 0xFFFF] >> 16) & 0xFF;
            const fg: u8 = @intCast(at & 0x0F);
            var bg: u8 = @intCast(at >> 4);
            if (blink) {
                bg &= 7;
                if (at & 0x80 != 0 and blink_off) bits = 0;
            }
            if (rs == ul and at & 0x77 == 0x01) bits = 0xFF;
            if (cur_on and (m & 0xFFFF) == (cur & 0xFFFF)) bits = 0xFF;
            const o = self.line[cc * cw ..][0..9];
            inline for (0..8) |i| o[i] = if (bits & (0x80 >> i) != 0) fg else bg;
            if (nine) o[8] = if (lge and ch >= 0xC0 and ch <= 0xDF and bits & 1 != 0) fg else bg;
        }
    }
};
