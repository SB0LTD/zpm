//! @zpm/dxg — NVIDIA GPUs through WSL's /dev/dxg (dxgkrnl, GPU
//! paravirtualization), in pure Sig: no libc, no NVIDIA library.
//!
//! WSL gives a Linux process the Windows host's GPU through dxgkrnl's
//! D3DKMT calls; NVIDIA's WSL driver adds its private data to them and
//! submits work from user space (a GPFIFO ring in shared memory, then a
//! doorbell call). zpm does the same (tools/dxgtrace.sig watched NVIDIA's
//! driver do it), so the GPU-forwarding host for a Galaxy VM, and any zpm
//! GPU work on a Windows machine, runs on the real RTX:
//!
//!   kmt     dxgkrnl's calls and arguments (the public uapi header's)
//!   nv      NVIDIA's private data for them
//!   gpu     a Gpu: adapter, device, context, ring, memory, submit, wait
//!   device  a Gpu as an nvidia.device.Device (compute, the 3D engine)
//!
//! Learned and checked on the Legion's RTX 5070 Laptop GPU (GB206), NVIDIA's
//! Windows driver 592.15.

pub const kmt = @import("kmt.sig");
pub const nv = @import("nv.sig");
pub const gpu = @import("gpu.sig");
pub const device = @import("device.sig");

pub const Gpu = gpu.Gpu;
pub const DxgDevice = device.DxgDevice;

test {
    _ = kmt;
    _ = nv;
    _ = gpu;
    _ = device;
}
