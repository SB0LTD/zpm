//! @zpm/va — Galaxy's VA-API driver for the RTX's hardware video decoder
//! (NVDEC, NVCFB0 on GB206): H.264, HEVC Main, VP9 profile 0 and AV1 Main,
//! and its encoder (NVENC, NVCFB7): H.264 and HEVC Main, in
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
//!   vp8.sig          VP8: nvdec_vp8_pic_s, its probability table, one
//!                    frame's pushbuffer
//!   vaapi_vp8.sig    libva 2.22's VP8 decode buffers
//!   vp9.sig          VP9 profile 0: nvdec_vp9_pic_s, the probability
//!                    contexts (compressed header, adaptation from the
//!                    decoder's counts), one frame's pushbuffer
//!   vp9_tables.sig   VP9's default probabilities (libvpx's)
//!   vaapi_vp9.sig    libva 2.22's VP9 decode buffers
//!   av1.sig          AV1 Main: nvdec_av1_pic_s, the CDF table pool, tiles,
//!                    motion and segment buffers, one frame's pushbuffer
//!   av1_cdf.sig      AV1's default CDF tables as the decoder reads them
//!   vaapi_av1.sig    libva 2.22's AV1 decode buffers
//!   vaapi_enc.sig    libva 2.22's encode side: EncSlice, attributes, the
//!                    coded buffer, H.264 and HEVC encode buffers
//!   bits.sig         the bit writer: Exp-Golomb, NAL units' emulation
//!                    prevention
//!   nvenc.sig        the encoder: methods, the setup's fields (from
//!                    nvenc_drv.h by gcc), the input's tiling, a picture's
//!                    pushbuffer
//!   enc_h264.sig     H.264's SPS and PPS, the encoder's H.264 setup
//!   enc_hevc.sig     HEVC's VPS, SPS and PPS, the encoder's HEVC setup
//!   encode.sig       an encode context: buffers, packed headers, rate
//!                    control, EndPicture's work, the coded buffer
//!   driver.sig       the VA-API objects and calls over the node
//!   driver_test.sig  the driver against the fake node's pretend decoder
//!                    and encoder
//!   hevc_stream_test.sig  the slice-header parse on x265's real stream

pub const vaapi = @import("vaapi.sig");
pub const nvdec = @import("nvdec.sig");
pub const tiling = @import("tiling.sig");
pub const node = @import("node.sig");
pub const codec = @import("codec.sig");
pub const hevc = @import("hevc.sig");
pub const vp8 = @import("vp8.sig");
pub const vp9 = @import("vp9.sig");
pub const av1 = @import("av1.sig");
pub const vaapi_enc = @import("vaapi_enc.sig");
pub const bits = @import("bits.sig");
pub const nvenc = @import("nvenc.sig");
pub const enc_h264 = @import("enc_h264.sig");
pub const enc_hevc = @import("enc_hevc.sig");
pub const encode = @import("encode.sig");
pub const driver = @import("driver.sig");

test {
    _ = vaapi;
    _ = nvdec;
    _ = tiling;
    _ = node;
    _ = codec;
    _ = hevc;
    _ = vp8;
    _ = @import("vaapi_vp8.sig");
    _ = vp9;
    _ = @import("vp9_tables.sig");
    _ = @import("vaapi_vp9.sig");
    _ = av1;
    _ = vaapi_enc;
    _ = bits;
    _ = nvenc;
    _ = enc_h264;
    _ = enc_hevc;
    _ = encode;
    _ = driver;
    _ = @import("driver_test.sig");
    _ = @import("hevc_stream_test.sig");
}
