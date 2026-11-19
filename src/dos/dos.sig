//! @zpm/dos — a PC that runs DOS programs, in pure Sig: no C, no
//! allocator, no emulator's code (clean room, from Intel's and the chips'
//! data sheets and the published DOS and BIOS interfaces). Galaxy's DOS
//! personality (galaxy-dos) runs one per program; it works the same on
//! x86-64 and AArch64.
//!
//!   machine.sig     the PC: bus, ports, the ROM's service traps, time
//!   regs.sig        the CPU's registers as services see them
//!   mem.sig         16 MiB of RAM, the A20 gate
//!   host.sig        what the PC asks of its host (files, clock, log)
//!   host_linux.sig  that host on Linux system calls (no libc)
//!   cpu.sig         the 386 in real and protected mode, and the x87
//!   cpu_pm.sig      protected mode: descriptors, gates, the IDT, paging
//!   pic.sig         the two 8259 interrupt controllers
//!   pit.sig         the 8254 timer, the PC speaker
//!   kbd.sig         the 8042 keyboard controller
//!   dma.sig         the two 8237 DMA controllers
//!   vga.sig         the VGA
//!   video_bios.sig  int 10h
//!   sb.sig          the Sound Blaster 16's DSP and mixer
//!   opl.sig         its OPL3 (and the AdLib's OPL2)
//!   bios.sig        the BIOS's data area and its services
//!   dos21.sig       DOS: int 20h, 21h, 2Fh; mz.sig loads programs
//!   xms.sig         XMS and EMS
//!   mouse.sig       int 33h

pub const Machine = @import("machine.sig").Machine;
pub const Status = @import("machine.sig").Status;
pub const Size = @import("machine.sig").Size;
pub const host = @import("host.sig");
pub const Host = host.Host;
pub const regs = @import("regs.sig");
pub const cpu = @import("cpu.sig");
/// The host on Linux system calls (galaxy-dos, tools/dosrun.sig).
pub const host_linux = @import("host_linux.sig");

test {
    _ = @import("regs.sig");
    _ = @import("mem.sig");
    _ = @import("host.sig");
    _ = @import("machine.sig");
    _ = @import("cpu.sig");
    _ = @import("pic.sig");
    _ = @import("pit.sig");
    _ = @import("kbd.sig");
    _ = @import("dma.sig");
    _ = @import("vga.sig");
    _ = @import("video_bios.sig");
    _ = @import("sb.sig");
    _ = @import("opl.sig");
    _ = @import("bios.sig");
    _ = @import("dos21.sig");
    _ = @import("xms.sig");
    _ = @import("mouse.sig");
    _ = @import("machine_test.sig");
    _ = @import("host_linux.sig");
    _ = @import("cpu_test.sig");
    _ = @import("cpu_pm_test.sig");
    _ = @import("vga_test.sig");
    _ = @import("bios_test.sig");
    _ = @import("xms_test.sig");
    _ = @import("mouse_test.sig");
    _ = @import("sb_ring.sig");
}
