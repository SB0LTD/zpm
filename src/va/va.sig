//! @zpm/va — Galaxy's VA-API driver for the RTX's hardware video decoder
//! (NVDEC, NVCFB0 on GB206), H.264 first, in pure Sig: no C, no C library,
//! no allocator. libgalaxy_va.sig is the shared library's root
//! (galaxy_drv_video.so) and says what works and what waits for a boot.
//!
//!   vaapi.sig        libva 2.22's driver ABI and VA-API's H.264 buffers
//!   nvdec.sig        the decoder: methods, nvdec_h264_pic_s, one frame's
//!                    pushbuffer (after Mesa NVK's H.264 decode)
//!   tiling.sig       block-linear pictures and their copy to linear NV12
//!   node.sig         Galaxy's render node: G_ALLOC, G_VSUBMIT, G_VWAIT,
//!                    PRIME; a fake kernel for tests
//!   driver.sig       the VA-API objects and calls over the node
//!   driver_test.sig  the driver against the fake node's pretend decoder

pub const vaapi = @import("vaapi.sig");
pub const nvdec = @import("nvdec.sig");
pub const tiling = @import("tiling.sig");
pub const node = @import("node.sig");
pub const driver = @import("driver.sig");

test {
    _ = vaapi;
    _ = nvdec;
    _ = tiling;
    _ = node;
    _ = driver;
    _ = @import("driver_test.sig");
}
