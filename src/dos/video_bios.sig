//! The video BIOS: int 10h on the VGA (vga.sig): set mode (text 00h-03h
//! and 07h, CGA 04h-06h, EGA 0Dh-10h, VGA 11h-13h; bit 7 keeps memory),
//! cursor, scrolling, characters and pixels, palette and DAC functions
//! (AH=10h), fonts (AH=11h, the 8x8/8x14/8x16 font pointers), alternate
//! select (AH=12h), write string (AH=13h), display combination (AH=1Ah),
//! state (AH=1Bh), and VESA's 4Fh answered "not supported" until it is.
//! The BIOS data area's video fields stay in step (0x449-0x488).
//! STUB: the API; the services come next.

const std = @import("std");
const Regs = @import("regs.sig").Regs;
const Memory = @import("mem.sig").Memory;
const Vga = @import("vga.sig").Vga;

/// Sets up the adapter and the BIOS data area as the BIOS does at boot
/// (mode 03h), and puts the fonts where int 10h/1130h says they are
/// (`rom`: the video ROM's segment, 0xC000).
pub fn boot(vga: *Vga, mem: *Memory) void {
    _ = vga;
    _ = mem;
}

/// int 10h.
pub fn int10(r: *Regs, mem: *Memory, vga: *Vga) void {
    _ = mem;
    _ = vga;
    r.setAh(0);
}
