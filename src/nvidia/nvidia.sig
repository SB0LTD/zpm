//! @zpm/nvidia — GPU compute on NVIDIA's Blackwell GeForce GPUs (sm_120:
//! the RTX 50 series) in pure Sig: the SASS instruction set, an assembler
//! for compute kernels, and the scheduling (control fields) it works out.
//! No CUDA, ptxas or vendor driver at build or run time. Mesa's NAK
//! compiler was read as documentation (see sm120.sig and sm120_sched.sig),
//! NVIDIA's latency tables come as Mesa ships them (sm120_latency.sig),
//! and ptxas's output for Galaxy's probe kernels is the test data
//! (sm120_vectors.txt, made by tools/gen_sm120_vectors.py).
//!
//! Galaxy launches the kernels on its own driver (src/kernel/nv_chan.sig:
//! the QMD, constant buffer 0, the stack's top at 0x37c, the parameters
//! from 0x380).

pub const sm120 = @import("sm120.sig");
pub const sm120_asm = @import("sm120_asm.sig");
pub const sm120_sched = @import("sm120_sched.sig");
pub const sm120_latency = @import("sm120_latency.sig");
pub const qmd = @import("qmd.sig");
pub const push = @import("push.sig");
pub const sm120_emu = @import("sm120_emu.sig");

test {
    _ = sm120;
    _ = sm120_asm;
    _ = sm120_sched;
    _ = qmd;
    _ = push;
    _ = sm120_emu;
}
