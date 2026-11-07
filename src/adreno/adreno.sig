//! @zpm/adreno — GPU compute on Qualcomm Adreno a7xx in pure Sig: the ir3
//! shader instruction set, an assembler for compute kernels, A7xx command
//! streams, an emulator to test kernels on any CPU, and the bring-up tests.
//! No Mesa, Vulkan or vendor driver: Mesa's freedreno sources were read as
//! documentation (see each file).

pub const ir3 = @import("ir3.sig");
pub const ir3_asm = @import("ir3_asm.sig");
pub const ir3_emu = @import("ir3_emu.sig");
pub const a7xx = @import("a7xx.sig");
pub const device = @import("device.sig");
pub const selftest = @import("selftest.sig");

test {
    _ = ir3;
    _ = ir3_asm;
    _ = ir3_emu;
    _ = a7xx;
    _ = device;
    _ = selftest;
}
