//! DOS's console: CON's output as a teletype into text-mode video memory
//! (B800:0, or B000:0 in mode 7, at the BIOS's cursor at 0x450, scrolling
//! at the bottom; any int 10h finds the screen and cursor as DOS left
//! them), a copy in a ring for a machine that would rather hand the bytes
//! to int 10h's teletype, and each line in the host's log ("dos: con: ...",
//! so a program's last words before it exits are seen). Input comes from
//! the BIOS's keyboard buffer: single keys (an extended key is 00h, then
//! its scan code) and the edited line of 0Ah and 3Fh.

const std = @import("std");
const Memory = @import("mem.sig").Memory;
const host_mod = @import("host.sig");
const Host = host_mod.Host;
const bios = @import("bios.sig");
const State = @import("dos_state.sig").State;

fn textMode(mem: *const Memory) ?u32 {
    return switch (mem.rdB(0x40, 0x49) & 0x7F) {
        0x00...0x03 => 0xB8000,
        0x07 => 0xB0000,
        else => null,
    };
}

/// One character to the screen at the BIOS's cursor (page 0x462).
fn teletype(mem: *Memory, c: u8) void {
    const base = textMode(mem) orelse return;
    const cols_w = mem.rdW(0x40, 0x4A);
    const cols: u32 = if (cols_w == 0) 80 else cols_w;
    const rows_b = mem.rdB(0x40, 0x84);
    const rows: u32 = if (rows_b == 0) 25 else @as(u32, rows_b) + 1;
    const page = mem.rdB(0x40, 0x62) & 7;
    const start = base + mem.rdW(0x40, 0x4E);
    const cur: u16 = 0x50 + @as(u16, page) * 2;
    var col: u32 = mem.rdB(0x40, cur);
    var row: u32 = mem.rdB(0x40, cur + 1);
    switch (c) {
        0x07 => return,
        0x08 => {
            if (col > 0) col -= 1;
        },
        0x0A => row += 1,
        0x0D => col = 0,
        else => {
            mem.wr8(start + (row * cols + col) * 2, c);
            col += 1;
            if (col >= cols) {
                col = 0;
                row += 1;
            }
        },
    }
    if (row >= rows) {
        // Scroll the page up a line; the new line blank, grey on black.
        const line = cols * 2;
        var i: u32 = 0;
        while (i < (rows - 1) * line) : (i += 1) mem.wr8(start + i, mem.rd8(start + line + i));
        var x: u32 = 0;
        while (x < cols) : (x += 1) mem.wr16(start + (rows - 1) * line + x * 2, 0x0720);
        row = rows - 1;
    }
    mem.wrB(0x40, cur, @intCast(col));
    mem.wrB(0x40, cur + 1, @intCast(row));
}

/// A character to CON.
pub fn out(st: *State, mem: *Memory, host: Host, c: u8) void {
    if (st.tty_direct) teletype(mem, c);
    // The ring (the oldest byte goes when it is full).
    const at: u8 = @truncate(@as(u16, st.out_head) + st.out_len);
    st.out_ring[at] = c;
    if (st.out_len < st.out_ring.len) st.out_len += 1 else st.out_head +%= 1;
    // The log, a line at a time.
    switch (c) {
        '\n' => flushLog(st, host),
        '\r', 0x07 => {},
        0x08 => st.log_len -|= 1,
        else => {
            st.log_line[st.log_len] = if (c >= 0x20 and c < 0x7F) c else '.';
            st.log_len += 1;
            if (st.log_len == st.log_line.len) flushLog(st, host);
        },
    }
}

pub fn flushLog(st: *State, host: Host) void {
    if (st.log_len == 0) return;
    host.say("dos: con: {s}", .{st.log_line[0..st.log_len]});
    st.log_len = 0;
}

/// The bytes CON wrote since the last call (oldest first).
pub fn drain(st: *State, buf: []u8) usize {
    const n = @min(buf.len, st.out_len);
    for (buf[0..n]) |*b| {
        b.* = st.out_ring[st.out_head];
        st.out_head +%= 1;
    }
    st.out_len -= @intCast(n);
    return n;
}

pub fn outStr(st: *State, mem: *Memory, host: Host, s: []const u8) void {
    for (s) |c| out(st, mem, host, c);
}

/// A key waits (or the second half of an extended one).
pub fn ready(st: *const State, mem: *Memory) bool {
    return st.pending_scan != null or bios.keyPeek(mem, false) != null;
}

/// The next character from the keyboard: an extended key gives 00h, and
/// its scan code next time. Null: none waits.
pub fn getChar(st: *State, mem: *Memory) ?u8 {
    if (st.pending_scan) |s| {
        st.pending_scan = null;
        return s;
    }
    const k = bios.keyRead(mem, false) orelse return null;
    const ascii: u8 = @truncate(k);
    if (ascii == 0 and k != 0) st.pending_scan = @intCast(k >> 8);
    // (Ctrl+Break's 0000h reads as Ctrl+C)
    if (k == 0) return 0x03;
    return ascii;
}

pub fn flushInput(st: *State, mem: *Memory) void {
    bios.keyFlush(mem);
    st.pending_scan = null;
}

/// The edited line (0Ah, and 3Fh on CON): keys taken as they come, echoed,
/// Backspace and Esc edit it; true once Enter ends it (in st.line, without
/// the CR). `max`: the most characters it holds.
pub fn lineInput(st: *State, mem: *Memory, host: Host, max: u8) bool {
    if (!st.line_active) {
        st.line_active = true;
        st.line_len = 0;
    }
    while (getChar(st, mem)) |c| {
        switch (c) {
            0x0D => {
                out(st, mem, host, 0x0D);
                st.line_active = false;
                return true;
            },
            0x08 => if (st.line_len > 0) {
                st.line_len -= 1;
                outStr(st, mem, host, "\x08 \x08");
            },
            0x00 => _ = getChar(st, mem), // (an extended key: not in a line)
            0x1B => {
                outStr(st, mem, host, "\\\r\n");
                st.line_len = 0;
            },
            else => if (st.line_len < max and st.line_len < st.line.len) {
                st.line[st.line_len] = c;
                st.line_len += 1;
                out(st, mem, host, c);
            },
        }
    }
    return false;
}
