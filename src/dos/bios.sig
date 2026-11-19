//! The system BIOS, written in Sig: the data area at 0x400 (equipment,
//! memory size, keyboard buffer and flags, timer ticks, video fields set
//! by video_bios.sig), int 11h, 12h, 13h (no floppy or hard disk: "no
//! drive"), 15h (A20 functions 24xx, the extended memory size 88h, wait
//! 86h, the system configuration C0h, E801h, the block move 87h), 16h
//! (keyboard: read, peek, shift flags, store, typematic), 1Ah (ticks since
//! midnight, the RTC's time and date), int 09h's default handler (set-1
//! scan codes to the buffer's scan/ASCII pairs) and int 08h's (the tick
//! count and the midnight flag).
//!
//! Written from the published interfaces (IBM's AT BIOS listing of the
//! data area and services, Ralf Brown's Interrupt List); no BIOS's code.

const std = @import("std");
const regs = @import("regs.sig");
const Regs = regs.Regs;
const mem_mod = @import("mem.sig");
const Memory = mem_mod.Memory;
const host_mod = @import("host.sig");
const bus_mod = @import("dos_bus.sig");

/// The data area's segment, and its fields (offsets in it).
pub const BDA: u16 = 0x40;
pub const EQUIPMENT: u16 = 0x10;
pub const MEMORY_KB: u16 = 0x13;
pub const KFLAGS1: u16 = 0x17;
pub const KFLAGS2: u16 = 0x18;
pub const ALT_NUMPAD: u16 = 0x19;
pub const KHEAD: u16 = 0x1A;
pub const KTAIL: u16 = 0x1C;
pub const KBUF: u16 = 0x1E;
pub const KBUF_END: u16 = 0x3E;
pub const MOTOR_COUNT: u16 = 0x40;
pub const HARD_DISKS: u16 = 0x75;
pub const TICKS: u16 = 0x6C;
pub const MIDNIGHT: u16 = 0x70;
pub const BREAK_FLAG: u16 = 0x71;
pub const RESET_FLAG: u16 = 0x72;
pub const KSTART: u16 = 0x80;
pub const KEND: u16 = 0x82;
pub const KFLAGS3: u16 = 0x96;
pub const KLEDS: u16 = 0x97;

/// The ROM's segment and the system configuration table int 15h/C0h
/// points at (where the AT BIOS keeps it).
pub const ROM_SEG: u16 = 0xF000;
pub const CONFIG_TABLE: u16 = 0xE6F5;

/// The timer's ticks in a day (1193180 / 65536 Hz for 24 hours).
pub const TICKS_PER_DAY: u32 = 0x1800B0;
/// One tick, in microseconds.
pub const TICK_US: u32 = 54925;

// KFLAGS1's bits.
const RSHIFT: u8 = 0x01;
const LSHIFT: u8 = 0x02;
const CTRL: u8 = 0x04;
const ALT: u8 = 0x08;
const SCROLL_ON: u8 = 0x10;
const NUM_ON: u8 = 0x20;
const CAPS_ON: u8 = 0x40;
const INSERT_ON: u8 = 0x80;
// KFLAGS2's bits (keys held).
const LCTRL_DOWN: u8 = 0x01;
const LALT_DOWN: u8 = 0x02;
const SCROLL_DOWN: u8 = 0x10;
const NUM_DOWN: u8 = 0x20;
const CAPS_DOWN: u8 = 0x40;
const INSERT_DOWN: u8 = 0x80;
// KFLAGS3's bits.
const LAST_E1: u8 = 0x01;
const LAST_E0: u8 = 0x02;
const RCTRL_DOWN: u8 = 0x04;
const RALT_DOWN: u8 = 0x08;
const ENHANCED_KBD: u8 = 0x10;

pub const State = struct {
    /// Bytes of an E1 (Pause) sequence still to swallow.
    e1_left: u8 = 0,
    /// Extended memory above 1 MiB, KiB (E801h reports it).
    ext_kb: u16 = 0,
    /// What 88h reports: 0, as with HIMEM loaded (XMS owns that memory).
    int15_88_kb: u16 = 0,
    /// int 15h/86h in progress: the tick it ends at.
    waiting: bool = false,
    wait_left: u32 = 0,
    wait_last: u32 = 0,

    pub fn reset(self: *State) void {
        self.* = .{};
    }
};

// ── The data area ────────────────────────────────────────────────────────

fn rdB(mem: *const Memory, off: u16) u8 {
    return mem.rdB(BDA, off);
}
fn wrB(mem: *Memory, off: u16, v: u8) void {
    mem.wrB(BDA, off, v);
}
fn rdW(mem: *const Memory, off: u16) u16 {
    return mem.rdW(BDA, off);
}
fn wrW(mem: *Memory, off: u16, v: u16) void {
    mem.wrW(BDA, off, v);
}
fn setBits(mem: *Memory, off: u16, bits: u8, on: bool) void {
    const v = rdB(mem, off);
    wrB(mem, off, if (on) v | bits else v & ~bits);
}

/// The data area and the ROM's tables as at boot (`conv_kb`: conventional
/// memory in KiB, `ext_kb`: extended memory above 1 MiB in KiB). The video
/// fields (0x49-0x66, 0x84-0x8A, 0xA8) are video_bios's.
pub fn boot(st: *State, mem: *Memory, conv_kb: u16, ext_kb: u16) void {
    st.ext_kb = ext_kb;
    // No serial or parallel ports, no extended BIOS data area.
    var o: u16 = 0;
    while (o < 0x10) : (o += 1) wrB(mem, o, 0);
    // Equipment: a coprocessor, 80x25 colour at boot, no floppy drives.
    wrW(mem, EQUIPMENT, 0x0022);
    wrW(mem, MEMORY_KB, conv_kb);
    // Keyboard: an empty buffer, no shift states, a 101-key keyboard.
    wrB(mem, KFLAGS1, 0);
    wrB(mem, KFLAGS2, 0);
    wrB(mem, ALT_NUMPAD, 0);
    wrW(mem, KHEAD, KBUF);
    wrW(mem, KTAIL, KBUF);
    wrW(mem, KSTART, KBUF);
    wrW(mem, KEND, KBUF_END);
    wrB(mem, KFLAGS3, ENHANCED_KBD);
    wrB(mem, KLEDS, 0);
    // The clock (DOS sets it from the RTC at boot: setClock), no hard
    // disks the BIOS knows of, a cold boot.
    mem.wr32(mem_mod.Memory.lin(BDA, TICKS), 0);
    wrB(mem, MIDNIGHT, 0);
    wrB(mem, BREAK_FLAG, 0);
    wrW(mem, RESET_FLAG, 0);
    wrB(mem, HARD_DISKS, 0);
    wrB(mem, MOTOR_COUNT, 0);
    // The system configuration table (int 15h/C0h): 8 bytes follow;
    // model FCh (AT), submodel 01h, revision 0; a second 8259 and an RTC.
    const t = mem_mod.Memory.lin(ROM_SEG, CONFIG_TABLE);
    mem.copyIn(t, &.{ 0x08, 0x00, 0xFC, 0x01, 0x00, 0x60, 0x00, 0x00, 0x00, 0x00 });
}

/// The tick count from the wall clock (what the BIOS does from the RTC at
/// power-on; DOS calls it at boot with the host's time).
pub fn setClock(mem: *Memory, t: host_mod.Time) void {
    const cs: u64 = (@as(u64, t.hour) * 3600 + @as(u64, t.minute) * 60 + t.second) * 100 + t.hundredths;
    const n: u32 = @intCast(@min(cs * 1193180 / (65536 * 100), TICKS_PER_DAY - 1));
    mem.wr32(mem_mod.Memory.lin(BDA, TICKS), n);
    wrB(mem, MIDNIGHT, 0);
}

pub fn ticks(mem: *const Memory) u32 {
    return mem.rd32(mem_mod.Memory.lin(BDA, TICKS));
}

/// int 08h's default handler's work (the tick count, the midnight
/// rollover, the floppy motor's count); the machine then calls int 1Ch.
pub fn timerTick(st: *State, mem: *Memory) void {
    _ = st;
    var n = ticks(mem) +% 1;
    if (n >= TICKS_PER_DAY) {
        n = 0;
        wrB(mem, MIDNIGHT, 1);
    }
    mem.wr32(mem_mod.Memory.lin(BDA, TICKS), n);
    const motor = rdB(mem, MOTOR_COUNT);
    if (motor != 0) wrB(mem, MOTOR_COUNT, motor - 1);
}

// ── The keyboard ─────────────────────────────────────────────────────────

/// A key's four forms: plain, shifted, with Ctrl, with Alt (scan << 8 |
/// ASCII; 0: the combination gives nothing).
const Forms = [4]u16;

/// Set-1 make codes 00h-58h as the AT BIOS translates them (US layout).
const table: [0x59]Forms = blk: {
    var t = [_]Forms{.{ 0, 0, 0, 0 }} ** 0x59;
    t[0x01] = .{ 0x011B, 0x011B, 0x011B, 0x0100 };
    // The digit row: plain, shifted, Ctrl (only 2, 6, -), Alt (78h-83h).
    const plain = "1234567890-=";
    const shifted = "!@#$%^&*()_+";
    for (plain, 0..) |c, i| {
        const sc: u16 = 0x02 + i;
        t[sc] = .{ sc << 8 | c, sc << 8 | shifted[i], 0, (0x78 + i) << 8 };
    }
    t[0x03][2] = 0x0300;
    t[0x07][2] = 0x071E;
    t[0x0C][2] = 0x0C1F;
    t[0x0E] = .{ 0x0E08, 0x0E08, 0x0E7F, 0x0E00 };
    t[0x0F] = .{ 0x0F09, 0x0F00, 0x9400, 0xA500 };
    // Letters: lower, upper, the control code, Alt with no ASCII.
    const rows = [_]struct { at: u16, keys: []const u8 }{
        .{ .at = 0x10, .keys = "qwertyuiop" },
        .{ .at = 0x1E, .keys = "asdfghjkl" },
        .{ .at = 0x2C, .keys = "zxcvbnm" },
    };
    for (rows) |row| for (row.keys, 0..) |c, i| {
        const sc: u16 = row.at + i;
        t[sc] = .{ sc << 8 | c, sc << 8 | (c - 32), sc << 8 | (c - 96), sc << 8 };
    };
    t[0x1A] = .{ 0x1A5B, 0x1A7B, 0x1A1B, 0x1A00 };
    t[0x1B] = .{ 0x1B5D, 0x1B7D, 0x1B1D, 0x1B00 };
    t[0x1C] = .{ 0x1C0D, 0x1C0D, 0x1C0A, 0x1C00 };
    t[0x27] = .{ 0x273B, 0x273A, 0, 0x2700 };
    t[0x28] = .{ 0x2827, 0x2822, 0, 0x2800 };
    t[0x29] = .{ 0x2960, 0x297E, 0, 0x2900 };
    t[0x2B] = .{ 0x2B5C, 0x2B7C, 0x2B1C, 0x2B00 };
    t[0x33] = .{ 0x332C, 0x333C, 0, 0x3300 };
    t[0x34] = .{ 0x342E, 0x343E, 0, 0x3400 };
    t[0x35] = .{ 0x352F, 0x353F, 0, 0x3500 };
    t[0x37] = .{ 0x372A, 0x372A, 0x9600, 0x3700 };
    t[0x39] = .{ 0x3920, 0x3920, 0x3920, 0x3920 };
    // F1-F10: 3Bh-44h, shifted 54h-5Dh, Ctrl 5Eh-67h, Alt 68h-71h.
    var f: u16 = 0;
    while (f < 10) : (f += 1) t[0x3B + f] = .{ (0x3B + f) << 8, (0x54 + f) << 8, (0x5E + f) << 8, (0x68 + f) << 8 };
    // The keypad (NumLock or Shift: the shifted form, its digit).
    t[0x47] = .{ 0x4700, 0x4737, 0x7700, 0 };
    t[0x48] = .{ 0x4800, 0x4838, 0x8D00, 0 };
    t[0x49] = .{ 0x4900, 0x4939, 0x8400, 0 };
    t[0x4A] = .{ 0x4A2D, 0x4A2D, 0x8E00, 0x4A00 };
    t[0x4B] = .{ 0x4B00, 0x4B34, 0x7300, 0 };
    t[0x4C] = .{ 0x4C00, 0x4C35, 0x8F00, 0 };
    t[0x4D] = .{ 0x4D00, 0x4D36, 0x7400, 0 };
    t[0x4E] = .{ 0x4E2B, 0x4E2B, 0x9000, 0x4E00 };
    t[0x4F] = .{ 0x4F00, 0x4F31, 0x7500, 0 };
    t[0x50] = .{ 0x5000, 0x5032, 0x9100, 0 };
    t[0x51] = .{ 0x5100, 0x5133, 0x7600, 0 };
    t[0x52] = .{ 0x5200, 0x5230, 0x9200, 0 };
    t[0x53] = .{ 0x5300, 0x532E, 0x9300, 0 };
    t[0x57] = .{ 0x8500, 0x8700, 0x8900, 0x8B00 };
    t[0x58] = .{ 0x8600, 0x8800, 0x8A00, 0x8C00 };
    break :blk t;
};

/// The keys an E0 prefix makes (the grey keys): their four forms.
fn grey(code: u8) ?Forms {
    return switch (code) {
        0x1C => .{ 0xE00D, 0xE00D, 0xE00A, 0xA600 },
        0x35 => .{ 0xE02F, 0xE02F, 0x9500, 0xA400 },
        0x47 => .{ 0x47E0, 0x47E0, 0x77E0, 0x9700 },
        0x48 => .{ 0x48E0, 0x48E0, 0x8DE0, 0x9800 },
        0x49 => .{ 0x49E0, 0x49E0, 0x84E0, 0x9900 },
        0x4B => .{ 0x4BE0, 0x4BE0, 0x73E0, 0x9B00 },
        0x4D => .{ 0x4DE0, 0x4DE0, 0x74E0, 0x9D00 },
        0x4F => .{ 0x4FE0, 0x4FE0, 0x75E0, 0x9F00 },
        0x50 => .{ 0x50E0, 0x50E0, 0x91E0, 0xA000 },
        0x51 => .{ 0x51E0, 0x51E0, 0x76E0, 0xA100 },
        0x52 => .{ 0x52E0, 0x52E0, 0x92E0, 0xA200 },
        0x53 => .{ 0x53E0, 0x53E0, 0x93E0, 0xA300 },
        else => null,
    };
}

fn isKeypad(code: u8) bool {
    return switch (code) {
        0x47...0x49, 0x4B...0x4D, 0x4F...0x53 => true,
        else => false,
    };
}

/// The digit a keypad key types with Alt held (Alt+numpad ASCII).
fn keypadDigit(code: u8) ?u8 {
    return switch (code) {
        0x47 => 7,
        0x48 => 8,
        0x49 => 9,
        0x4B => 4,
        0x4C => 5,
        0x4D => 6,
        0x4F => 1,
        0x50 => 2,
        0x51 => 3,
        0x52 => 0,
        else => null,
    };
}

/// A key into the buffer (false: full, the key is lost).
pub fn keyStore(mem: *Memory, key: u16) bool {
    const start = rdW(mem, KSTART);
    const end = rdW(mem, KEND);
    const tail = rdW(mem, KTAIL);
    var next = tail +% 2;
    if (next >= end or next < start) next = start;
    if (next == rdW(mem, KHEAD)) return false;
    wrW(mem, tail, key);
    wrW(mem, KTAIL, next);
    return true;
}

/// The key at the buffer's head (enhanced form), or null.
fn keyPeekRaw(mem: *const Memory) ?u16 {
    const head = rdW(mem, KHEAD);
    if (head == rdW(mem, KTAIL)) return null;
    return rdW(mem, head);
}
fn keyDrop(mem: *Memory) void {
    const head = rdW(mem, KHEAD);
    if (head == rdW(mem, KTAIL)) return;
    var next = head +% 2;
    if (next >= rdW(mem, KEND) or next < rdW(mem, KSTART)) next = rdW(mem, KSTART);
    wrW(mem, KHEAD, next);
}
pub fn keyFlush(mem: *Memory) void {
    wrW(mem, KHEAD, rdW(mem, KTAIL));
}

/// A buffered key as function 00h/01h give it (the 84-key keyboard's
/// codes): the grey keys' E0 becomes 00h (and their scan code the white
/// key's), the keys that keyboard lacks (F11, F12, Ctrl and Alt forms
/// above 84h) are dropped.
fn standard(key: u16) ?u16 {
    var scan: u16 = key >> 8;
    var ascii: u16 = key & 0xFF;
    if (scan == 0xE0) scan = if (ascii == 0x0D or ascii == 0x0A) 0x1C else 0x35;
    if (ascii == 0xE0 and scan != 0) ascii = 0;
    if (ascii == 0xF0 and scan != 0) ascii = 0;
    if (scan > 0x84) return null;
    return scan << 8 | ascii;
}
/// Function 10h/11h's form: as stored, F0h ASCII as 00h.
fn enhanced(key: u16) u16 {
    if (key & 0xFF == 0xF0 and key >> 8 != 0) return key & 0xFF00;
    return key;
}

/// The next key without taking it (`ext`: function 11h's codes).
pub fn keyPeek(mem: *Memory, ext: bool) ?u16 {
    while (keyPeekRaw(mem)) |k| {
        if (ext) return enhanced(k);
        if (standard(k)) |s| return s;
        keyDrop(mem);
    }
    return null;
}
/// The next key, taken from the buffer (`ext`: function 10h's codes).
pub fn keyRead(mem: *Memory, ext: bool) ?u16 {
    const k = keyPeek(mem, ext) orelse return null;
    keyDrop(mem);
    return k;
}

fn shiftDown(f1: u8) bool {
    return f1 & (LSHIFT | RSHIFT) != 0;
}

/// int 09h's default handler: the scan code just read from port 0x60.
pub fn keyIrq(st: *State, mem: *Memory, code: u8) void {
    if (st.e1_left > 0) {
        st.e1_left -= 1;
        if (st.e1_left == 0) setBits(mem, KFLAGS3, LAST_E1, false);
        return;
    }
    switch (code) {
        0xE0 => {
            setBits(mem, KFLAGS3, LAST_E0, true);
            return;
        },
        // Pause: E1 1D 45 E1 9D C5 (this BIOS does not stop for it).
        0xE1 => {
            setBits(mem, KFLAGS3, LAST_E1, true);
            st.e1_left = 5;
            return;
        },
        // Keyboard answers (ACK, resend, overrun, echo; AAh is Left
        // Shift's release here, not the self-test).
        0x00, 0xEE, 0xFA, 0xFE, 0xFF => {
            setBits(mem, KFLAGS3, LAST_E0, false);
            return;
        },
        else => {},
    }
    const e0 = rdB(mem, KFLAGS3) & LAST_E0 != 0;
    setBits(mem, KFLAGS3, LAST_E0, false);
    const up = code & 0x80 != 0;
    const make = code & 0x7F;
    const down = !up;

    // The shift keys.
    switch (make) {
        0x2A, 0x36 => {
            // (E0 2A / E0 36 are the keyboard's fake shifts around grey keys)
            if (!e0) setBits(mem, KFLAGS1, if (make == 0x2A) LSHIFT else RSHIFT, down);
            return;
        },
        0x1D => {
            if (e0) setBits(mem, KFLAGS3, RCTRL_DOWN, down) else setBits(mem, KFLAGS2, LCTRL_DOWN, down);
            const any = rdB(mem, KFLAGS2) & LCTRL_DOWN != 0 or rdB(mem, KFLAGS3) & RCTRL_DOWN != 0;
            setBits(mem, KFLAGS1, CTRL, any);
            return;
        },
        0x38 => {
            if (e0) setBits(mem, KFLAGS3, RALT_DOWN, down) else setBits(mem, KFLAGS2, LALT_DOWN, down);
            const any = rdB(mem, KFLAGS2) & LALT_DOWN != 0 or rdB(mem, KFLAGS3) & RALT_DOWN != 0;
            setBits(mem, KFLAGS1, ALT, any);
            if (!any) {
                // Alt released: the character typed on the keypad.
                const acc = rdB(mem, ALT_NUMPAD);
                if (acc != 0) _ = keyStore(mem, acc);
                wrB(mem, ALT_NUMPAD, 0);
            }
            return;
        },
        0x3A => {
            if (down and rdB(mem, KFLAGS2) & CAPS_DOWN == 0) wrB(mem, KFLAGS1, rdB(mem, KFLAGS1) ^ CAPS_ON);
            setBits(mem, KFLAGS2, CAPS_DOWN, down);
            updateLeds(mem);
            return;
        },
        0x45 => {
            if (e0) return;
            if (rdB(mem, KFLAGS1) & CTRL != 0) return; // (Ctrl+NumLock: pause)
            if (down and rdB(mem, KFLAGS2) & NUM_DOWN == 0) wrB(mem, KFLAGS1, rdB(mem, KFLAGS1) ^ NUM_ON);
            setBits(mem, KFLAGS2, NUM_DOWN, down);
            updateLeds(mem);
            return;
        },
        0x46 => {
            const f1 = rdB(mem, KFLAGS1);
            if (f1 & CTRL != 0) {
                // Ctrl+Break: the break flag, an empty buffer, a 0000h key.
                if (down) {
                    setBits(mem, BREAK_FLAG, 0x80, true);
                    keyFlush(mem);
                    _ = keyStore(mem, 0x0000);
                }
                return;
            }
            if (down and rdB(mem, KFLAGS2) & SCROLL_DOWN == 0) wrB(mem, KFLAGS1, f1 ^ SCROLL_ON);
            setBits(mem, KFLAGS2, SCROLL_DOWN, down);
            updateLeds(mem);
            return;
        },
        else => {},
    }
    if (up) {
        if (make == 0x52) setBits(mem, KFLAGS2, INSERT_DOWN, false);
        return;
    }

    const f1 = rdB(mem, KFLAGS1);
    const alt = f1 & ALT != 0;
    const ctrl = f1 & CTRL != 0;
    const shift = shiftDown(f1);
    // Ctrl+Alt+Del would reboot: this PC ignores it.
    if (ctrl and alt and make == 0x53) return;
    // Print Screen and SysReq: nothing (no printer, no int 15h/85h users).
    if ((e0 and make == 0x37) or make == 0x54) return;

    if (e0) {
        const forms = grey(make) orelse return; // (Windows keys and others)
        if (make == 0x52 and !alt and !ctrl) insertToggle(mem);
        const k = forms[if (alt) 3 else if (ctrl) 2 else if (shift) 1 else 0];
        if (k != 0) _ = keyStore(mem, k);
        return;
    }
    if (make >= table.len) return;

    if (isKeypad(make)) {
        if (alt) {
            if (keypadDigit(make)) |d| wrB(mem, ALT_NUMPAD, rdB(mem, ALT_NUMPAD) *% 10 +% d);
            return;
        }
        const forms = table[make];
        const digits = (f1 & NUM_ON != 0) != shift;
        if (make == 0x52 and !ctrl and !digits) insertToggle(mem);
        const k = if (ctrl) forms[2] else if (digits) forms[1] else forms[0];
        if (k != 0) _ = keyStore(mem, k);
        return;
    }

    const forms = table[make];
    const ascii = forms[0] & 0xFF;
    const letter = ascii >= 'a' and ascii <= 'z';
    const upper = if (letter) (f1 & CAPS_ON != 0) != shift else shift;
    const k = if (alt) forms[3] else if (ctrl) forms[2] else if (upper) forms[1] else forms[0];
    if (k != 0) _ = keyStore(mem, k);
}

fn insertToggle(mem: *Memory) void {
    if (rdB(mem, KFLAGS2) & INSERT_DOWN == 0) wrB(mem, KFLAGS1, rdB(mem, KFLAGS1) ^ INSERT_ON);
    setBits(mem, KFLAGS2, INSERT_DOWN, true);
}

fn updateLeds(mem: *Memory) void {
    const f1 = rdB(mem, KFLAGS1);
    var l = rdB(mem, KLEDS) & 0xF8;
    if (f1 & SCROLL_ON != 0) l |= 1;
    if (f1 & NUM_ON != 0) l |= 2;
    if (f1 & CAPS_ON != 0) l |= 4;
    wrB(mem, KLEDS, l);
}

// ── Services ─────────────────────────────────────────────────────────────

pub fn int11(r: *Regs, mem: *Memory) void {
    r.setAx(mem.rdW(BDA, EQUIPMENT));
}
pub fn int12(r: *Regs, mem: *Memory) void {
    r.setAx(mem.rdW(BDA, MEMORY_KB));
}

/// int 13h: no drives. Function 15h (drive type) says "none"; the others
/// fail with "invalid function".
pub fn int13(r: *Regs, mem: *Memory) void {
    _ = mem;
    if (r.ah() == 0x15) {
        r.setAh(0x00);
        r.ok();
        return;
    }
    r.fail(0x0100);
}

/// int 15h (see int15Wait; this form cannot make 86h wait).
pub fn int15(st: *State, r: *Regs, mem: *Memory, a20: *bool) void {
    _ = int15Wait(st, r, mem, a20, bus_mod.MemBus{ .mem = mem });
}

/// int 15h: false while function 86h waits (the machine runs it again
/// after the next interrupt). `bus` serves 87h's moves that touch the
/// adapter area (the machine; or bus_mod.MemBus for RAM alone).
pub fn int15Wait(st: *State, r: *Regs, mem: *Memory, a20: *bool, bus: anytype) bool {
    switch (r.ah()) {
        0x24 => switch (r.al()) {
            0x00, 0x01 => {
                a20.* = r.al() == 0x01;
                r.setAh(0);
                r.ok();
            },
            0x02 => {
                r.setAl(if (a20.*) 1 else 0);
                r.setAh(0);
                r.setCx(0);
                r.ok();
            },
            0x03 => {
                // Supported through the keyboard controller and port 92h.
                r.setBx(0x0003);
                r.setAh(0);
                r.ok();
            },
            else => unsupported(r),
        },
        // The keyboard intercept: CF set = process the key as it is.
        0x4F => r.setFlag(regs.CF, true),
        // SysReq: nobody hooks it.
        0x85 => {
            r.setAh(0);
            r.ok();
        },
        0x86 => return wait(st, r, mem),
        0x87 => blockMove(r, mem, a20, bus),
        0x88 => {
            r.setAx(st.int15_88_kb);
            r.ok();
        },
        // Device busy / interrupt complete (the BIOS's own waits).
        0x90, 0x91 => {
            r.setAh(0);
            r.ok();
        },
        0xC0 => {
            r.setSeg(regs.ES, ROM_SEG);
            r.setBx(CONFIG_TABLE);
            r.setAh(0);
            r.ok();
        },
        0xE8 => if (r.al() == 0x01) {
            // E801h: KiB from 1 to 16 MiB, then 64 KiB blocks above 16 MiB.
            const lo: u16 = @min(st.ext_kb, 15 * 1024);
            const hi: u16 = @intCast((@as(u32, st.ext_kb) - lo) / 64);
            r.setAx(lo);
            r.setCx(lo);
            r.setBx(hi);
            r.setDx(hi);
            r.ok();
        } else unsupported(r),
        else => unsupported(r),
    }
    return true;
}

fn unsupported(r: *Regs) void {
    r.setAh(0x86);
    r.setFlag(regs.CF, true);
}

/// 86h: wait CX:DX microseconds, counted in timer ticks (a wait shorter
/// than half a tick returns at once).
fn wait(st: *State, r: *Regs, mem: *Memory) bool {
    const now = ticks(mem);
    if (!st.waiting) {
        const us: u32 = (@as(u32, r.cx()) << 16) | r.dx();
        const n = (us + TICK_US / 2) / TICK_US;
        if (n == 0) {
            r.ok();
            return true;
        }
        st.waiting = true;
        st.wait_left = n;
        st.wait_last = now;
        return false;
    }
    // (ticks wrap at midnight; count the ticks seen)
    const seen = if (now >= st.wait_last) now - st.wait_last else now + TICKS_PER_DAY - st.wait_last;
    st.wait_last = now;
    st.wait_left -|= seen;
    if (st.wait_left > 0) return false;
    st.waiting = false;
    r.ok();
    return true;
}

/// A descriptor's 32-bit base (386 form: bits 24-31 at +7).
fn descBase(mem: *const Memory, at: u32) u32 {
    return @as(u32, mem.rd16(at + 2)) | (@as(u32, mem.rd8(at + 4)) << 16) | (@as(u32, mem.rd8(at + 7)) << 24);
}

/// 87h: CX words from the GDT's source descriptor (ES:SI+10h) to its
/// destination (ES:SI+18h), with A20 on for the move.
fn blockMove(r: *Regs, mem: *Memory, a20: *bool, bus: anytype) void {
    const gdt = r.base[regs.ES] +% r.si();
    const src = descBase(mem, gdt + 0x10);
    const dst = descBase(mem, gdt + 0x18);
    const n: u32 = @as(u32, r.cx()) * 2;
    if (r.cx() > 0x8000) {
        r.setAh(0x01); // (parity error: the closest answer for a bad count)
        r.setFlag(regs.CF, true);
        return;
    }
    const was = a20.*;
    a20.* = true;
    const ok = bus_mod.copy(bus, mem, dst, src, n);
    a20.* = was;
    if (!ok) {
        r.setAh(0x03); // (address line 20 gating failed)
        r.setFlag(regs.CF, true);
        return;
    }
    r.setAh(0);
    r.ok();
    r.setFlag(regs.ZF, true);
}

/// int 16h: false when the call must wait (00h/10h with an empty buffer):
/// the machine runs it again after the next interrupt.
pub fn int16(st: *State, r: *Regs, mem: *Memory) bool {
    _ = st;
    switch (r.ah()) {
        0x00, 0x10 => {
            const k = keyRead(mem, r.ah() == 0x10) orelse return false;
            r.setAx(k);
        },
        0x01, 0x11 => {
            if (keyPeek(mem, r.ah() == 0x11)) |k| {
                r.setAx(k);
                r.setFlag(regs.ZF, false);
            } else r.setFlag(regs.ZF, true);
        },
        0x02 => r.setAl(rdB(mem, KFLAGS1)),
        0x12 => {
            const f2 = rdB(mem, KFLAGS2);
            const f3 = rdB(mem, KFLAGS3);
            var h: u8 = f2 & (LCTRL_DOWN | LALT_DOWN);
            if (f3 & RCTRL_DOWN != 0) h |= 0x04;
            if (f3 & RALT_DOWN != 0) h |= 0x08;
            h |= f2 & (SCROLL_DOWN | NUM_DOWN | CAPS_DOWN);
            if (f2 & 0x04 != 0) h |= 0x80; // (SysReq held)
            r.setAl(rdB(mem, KFLAGS1));
            r.setAh(h);
        },
        // Typematic rate and delay: taken (the host repeats keys).
        0x03 => {},
        0x05 => r.setAl(if (keyStore(mem, r.cx())) 0 else 1),
        // Capabilities: 0Ah and 10h-12h.
        0x09 => r.setAl(0x30),
        // The keyboard's ID: an MF2 keyboard, translated.
        0x0A => r.setBx(0x41AB),
        else => {},
    }
    return true;
}

fn bcd(x: u32) u8 {
    return @intCast(((x / 10) % 10) << 4 | (x % 10));
}

pub fn int1a(st: *State, r: *Regs, mem: *Memory, host: host_mod.Host) void {
    _ = st;
    switch (r.ah()) {
        0x00 => {
            const n = ticks(mem);
            r.setCx(@intCast(n >> 16));
            r.setDx(@truncate(n));
            r.setAl(rdB(mem, MIDNIGHT));
            wrB(mem, MIDNIGHT, 0);
        },
        0x01 => {
            const n = (@as(u32, r.cx()) << 16) | r.dx();
            mem.wr32(mem_mod.Memory.lin(BDA, TICKS), @min(n, TICKS_PER_DAY - 1));
            wrB(mem, MIDNIGHT, 0);
        },
        0x02 => {
            const t = host.now();
            r.setCh(bcd(t.hour));
            r.setCl(bcd(t.minute));
            r.setDh(bcd(t.second));
            r.setDl(0);
            r.ok();
        },
        0x04 => {
            const t = host.now();
            r.setCh(bcd(t.year / 100));
            r.setCl(bcd(t.year % 100));
            r.setDh(bcd(t.month));
            r.setDl(bcd(t.day));
            r.ok();
        },
        // Setting the RTC's time or date, cancelling the alarm: taken (the
        // host's clock stays as it is).
        0x03, 0x05, 0x07 => r.ok(),
        // The alarm, the PS/2's day count, the PCI BIOS: none here.
        else => r.setFlag(regs.CF, true),
    }
}

test {
    _ = @import("bios_test.sig");
}
