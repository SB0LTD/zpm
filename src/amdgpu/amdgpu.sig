//! @zpm/amdgpu — GPU compute on AMD's GCN GPUs in pure Sig. First target:
//! GCN 4 (gfx803: Polaris 21, the Radeon Pro 555X/560X in the MacBook Pro
//! 15" 2018). The instruction set (encoder, decoder, printer, parser), an
//! assembler for kernels, the kernel descriptor and dispatch registers a
//! PM4 dispatch consumes, and an emulator of a wave64 to test kernels on any
//! CPU. No ROCm, LLVM, Mesa or vendor driver at build or run time: AMD's
//! public GCN3 ISA guide is the source, LLVM's assembler output is the test
//! data (gcn3_vectors.txt), Mesa and LLVM were read as documentation only.

pub const gcn3 = @import("gcn3.sig");
pub const gcn3_asm = @import("gcn3_asm.sig");
pub const gcn3_emu = @import("gcn3_emu.sig");
pub const dispatch = @import("dispatch.sig");

test {
    _ = gcn3;
    _ = gcn3_asm;
    _ = gcn3_emu;
    _ = dispatch;
}
