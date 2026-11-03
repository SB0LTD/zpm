//! @zpm/nvidia — GPU compute on NVIDIA's Blackwell GeForce GPUs (sm_120:
//! the RTX 50 series) in pure Sig: the SASS instruction set and an
//! assembler for compute kernels. No CUDA, ptxas or vendor driver at build
//! or run time. Mesa's NAK compiler was read as documentation (see
//! sm120.sig), and ptxas's output for Galaxy's probe kernels is the test
//! data (sm120_vectors.txt, made by tools/gen_sm120_vectors.py).
//!
//! Galaxy launches the kernels on its own driver (src/kernel/nv_chan.sig:
//! the QMD, constant buffer 0, the stack's top at 0x37c, the parameters
//! from 0x380).

pub const sm120 = @import("sm120.sig");
pub const sm120_asm = @import("sm120_asm.sig");

test {
    _ = sm120;
    _ = sm120_asm;
}
