//! Copies between physical addresses for the services that move memory
//! (int 15h/87h, XMS's 0Bh, EMS's 57h). Inside RAM proper they are one
//! memmove; a range that touches the adapter area (0xA0000-0xFFFFF: video
//! memory, the EMS page frame, the ROM) goes byte by byte through `bus`,
//! which is the machine (its rd8/wr8 route those addresses to the devices)
//! or `MemBus` (RAM alone: tests, and callers that have no machine).
//! The caller turns A20 on for the move, as the BIOS and HIMEM do.

const std = @import("std");
const mem_mod = @import("mem.sig");
const Memory = mem_mod.Memory;

/// A bus over RAM alone.
pub const MemBus = struct {
    mem: *Memory,
    pub fn rd8(b: MemBus, a: u32) u8 {
        return b.mem.rd8(a);
    }
    pub fn wr8(b: MemBus, a: u32, v: u8) void {
        b.mem.wr8(a, v);
    }
};

const ADAPTER_LO: u32 = mem_mod.CONVENTIONAL;
const ADAPTER_HI: u32 = mem_mod.MEG;

fn touchesAdapter(a: u32, n: u32) bool {
    const end = a +| n;
    return a < ADAPTER_HI and end > ADAPTER_LO;
}

/// `n` bytes from `src` to `dst` (physical addresses below 16 MiB), as
/// memmove does when the two overlap. False if a range leaves RAM.
pub fn copy(bus: anytype, mem: *Memory, dst: u32, src: u32, n: u32) bool {
    if (n == 0) return true;
    if (src +| n > mem_mod.RAM or dst +| n > mem_mod.RAM) return false;
    if (!touchesAdapter(src, n) and !touchesAdapter(dst, n)) {
        const d = mem.ram[dst..][0..n];
        const s = mem.ram[src..][0..n];
        if (dst <= src) std.mem.copyForwards(u8, d, s) else std.mem.copyBackwards(u8, d, s);
        return true;
    }
    if (dst <= src) {
        var i: u32 = 0;
        while (i < n) : (i += 1) bus.wr8(dst + i, bus.rd8(src + i));
    } else {
        var i: u32 = n;
        while (i > 0) {
            i -= 1;
            bus.wr8(dst + i, bus.rd8(src + i));
        }
    }
    return true;
}

/// Swaps `n` bytes between two ranges that do not overlap (EMS's 5701h).
pub fn exchange(bus: anytype, mem: *Memory, a: u32, b: u32, n: u32) bool {
    if (a +| n > mem_mod.RAM or b +| n > mem_mod.RAM) return false;
    if (!touchesAdapter(a, n) and !touchesAdapter(b, n)) {
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            const t = mem.ram[a + i];
            mem.ram[a + i] = mem.ram[b + i];
            mem.ram[b + i] = t;
        }
        return true;
    }
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const t = bus.rd8(a + i);
        bus.wr8(a + i, bus.rd8(b + i));
        bus.wr8(b + i, t);
    }
    return true;
}
