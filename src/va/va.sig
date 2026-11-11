//! @zpm/va — Galaxy's VA-API driver for the RTX's hardware video decoder
//! (NVDEC, NVCFB0 on GB206): H.264, HEVC Main and AV1 Main, VP9 coming, in
//! pure Sig: no C, no C library, no allocator. libgalaxy_va.sig is the shared library's root
//! (galaxy_drv_video.so) and says what works and what waits for a boot.
//!
//!   vaapi.sig        libva 2.22's driver ABI and VA-API's H.264 buffers
//!   nvdec.sig        the decoder: methods, nvdec_h264_pic_s, one frame's
//!                    pushbuffer (after Mesa NVK's H.264 decode)
//!   tiling.sig       block-linear pictures and their copy to linear NV12
//!   node.sig         Galaxy's render node: G_ALLOC, G_VSUBMIT, G_VWAIT,
//!                    PRIME; a fake kernel for tests
//!   codec.sig        what the driver gives a codec module, and asks of it
//!   hevc.sig         HEVC Main: nvdec_hevc_pic_s, its buffers, the slice
//!                    header's skipped bits, one frame's pushbuffer
//!   av1.sig          AV1 Main: nvdec_av1_pic_s, the CDF table pool, tiles,
//!                    motion and segment buffers, one frame's pushbuffer
//!   av1_cdf.sig      AV1's default CDF tables as the decoder reads them
//!   vaapi_av1.sig    libva 2.22's AV1 decode buffers
//!   driver.sig       the VA-API objects and calls over the node
//!   driver_test.sig  the driver against the fake node's pretend decoder
//!   hevc_stream_test.sig  the slice-header parse on x265's real stream

pub const vaapi = @import("vaapi.sig");
pub const nvdec = @import("nvdec.sig");
pub const tiling = @import("tiling.sig");
pub const node = @import("node.sig");
pub const codec = @import("codec.sig");
pub const hevc = @import("hevc.sig");
pub const av1 = @import("av1.sig");
pub const driver = @import("driver.sig");

test {
    _ = vaapi;
    _ = nvdec;
    _ = tiling;
    _ = node;
    _ = codec;
    _ = hevc;
    _ = av1;
    _ = driver;
    _ = @import("driver_test.sig");
    _ = @import("hevc_stream_test.sig");
}
