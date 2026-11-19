//! A Sound Blaster 16 at 0x220, IRQ 5 (or 7), DMA 1 and 5, as BLASTER=
//! A220 I5 D1 H5 T6 says: the DSP (reset, version 4.05, direct output,
//! single-cycle and auto-initialize 8- and 16-bit DMA output, pause and
//! resume, the speaker, time constant and sample rate, ADPCM where
//! asked), its interrupt acknowledge ports, the CT1745 mixer's volumes.
//! Its FM part (0x220-0x223, 0x228-0x229) is the OPL3 (opl.sig).
//! STUB: the API; the card comes next.

const std = @import("std");
const Memory = @import("mem.sig").Memory;
const Dma = @import("dma.sig").Dma;

pub const BASE: u16 = 0x220;
pub const IRQ: u4 = 5;
pub const DMA8: u3 = 1;
pub const DMA16: u3 = 5;

pub const SoundBlaster = struct {
    pub fn reset(self: *SoundBlaster) void {
        self.* = .{};
    }
    /// Emulated time goes on by `us` microseconds: the DSP pulls its DMA
    /// at its sample rate into its own ring; true when it wants IRQ 5
    /// (a block finished).
    pub fn advance(self: *SoundBlaster, dma: *Dma, mem: *Memory, us: u32) bool {
        _ = self;
        _ = dma;
        _ = mem;
        _ = us;
        return false;
    }
    /// The card's digital sound, added into `out` (interleaved stereo i16
    /// at `rate`), through the mixer's volumes.
    pub fn mix(self: *SoundBlaster, out: []i16, rate: u32) void {
        _ = self;
        _ = out;
        _ = rate;
    }
    pub fn in8(self: *SoundBlaster, port: u16) u8 {
        _ = self;
        _ = port;
        return 0xFF;
    }
    pub fn out8(self: *SoundBlaster, port: u16, v: u8) void {
        _ = self;
        _ = port;
        _ = v;
    }
};
