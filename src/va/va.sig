//! @zpm/va — Galaxy's VA-API driver for the RTX's hardware video decoder
//! (NVDEC, NVCFB0 on GB206): H.264, HEVC Main and Main10, VP9 profiles 0
//! and 2, AV1 Main (8- and 10-bit, film grain), zero copy (VRAM, block
//! linear, exported with NVIDIA's modifiers),
//! and its encoder (NVENC, NVCFB7): H.264 and HEVC Main; VP8 and VP9
//! encoders of its own on the GPU's compute engine (KIR kernels), in
//! pure Sig: no C, no C library, no allocator. libgalaxy_va.sig is the shared library's root
//! (galaxy_drv_video.so) and says what works and what waits for a boot.
//!
//!   vaapi.sig        libva 2.22's driver ABI and VA-API's H.264 buffers
//!   nvdec.sig        the decoder: methods, nvdec_h264_pic_s, one frame's
//!                    pushbuffer (after Mesa NVK's H.264 decode)
//!   tiling.sig       block-linear pictures, their DRM format modifiers,
//!                    and their copy to pitch linear on the CPU
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
//!   encode.sig       an encode context: buffers, packed headers, the
//!                    references kept, EndPicture's work, the coded buffer
//!   enc_rc.sig       the encoder's rate control: the driver's HRD-bound
//!                    controller, the firmware's (opt-in)
//!   enc_parse.sig    what an app's packed HEVC SPS and PPS say
//!   enc_av1.sig      AV1's OBUs (sequence and frame headers) and the
//!                    encoder's AV1 setup
//!   enc_import.sig   surfaces over an app's dma-bufs (DRM PRIME)
//!   enc_test.sig     the encoder through the driver and a pretend NVENC
//!   av1_grain.sig    AV1 film grain: the decoder's grain buffer (scaling
//!                    tables, grain templates) from a frame's parameters
//!   driver_10bit_test.sig  P010 surfaces through the driver
//!   convert.sig      a picture between its block-linear planes and a
//!                    pitch-linear copy, for CPU readers (the CPU's;
//!                    gpu_convert.sig: the RTX's, a KIR kernel)
//!   driver.sig       the VA-API objects and calls over the node
//!   driver_test.sig  the driver against the fake node's pretend decoder
//!                    and encoder
//!   hevc_stream_test.sig  the slice-header parse on x265's real stream
//!   h264_parse.sig   an H.264 stream read as a VA client reads it: parameter
//!                    sets, slice headers, POC, the DPB, output order
//!   video.sig        Decoder: a bitstream in, pictures out (display order),
//!                    for apps that hold no VA buffers (Galaxy's Windows
//!                    Media Foundation)
//!   hevc_parse.sig, vp8_read.sig, vp9_read.sig  the same for HEVC, VP8, VP9
//!   h264_stream_test.sig, hevc_parse_test.sig, video_test.sig  their tests
//!                    on x264's, x265's and libvpx's streams
//!   enc_vpx.sig      VP8 and VP9 encoding through VA-API: the buffers, a
//!                    picture's plan; vpx_driver_test.sig through the driver
//!   vpx_dsl.sig      the encoders' kernels' language: one source, run on
//!                    the CPU or built as KIR (vpx_kir.sig); vpx_gpu.sig
//!                    runs them on the RTX (the shared library's)
//!   vpx_bool.sig     the boolean coder VP8 and VP9 write with
//!   vp8_kernels.sig  VP8's pixel work; enc_vp8.sig its frames and
//!                    bitstream (vp8_tables.sig)
//!   vp9_kernels.sig  VP9's pixel work (vp9_tx.sig: libvpx's transforms);
//!                    enc_vp9.sig its frames and bitstream
//!                    (vp9_enc_tables.sig)

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
pub const enc_rc = @import("enc_rc.sig");
pub const enc_parse = @import("enc_parse.sig");
pub const enc_av1 = @import("enc_av1.sig");
pub const enc_import = @import("enc_import.sig");
pub const convert = @import("convert.sig");
pub const driver = @import("driver.sig");
pub const h264_parse = @import("h264_parse.sig");
pub const video = @import("video.sig");
pub const hevc_parse = @import("hevc_parse.sig");
pub const vp8_read = @import("vp8_read.sig");
pub const vp9_read = @import("vp9_read.sig");
/// (the RTX converting pictures for a CPU reader; they import the `gpu` and
/// `gfxapi` modules, so a build that names them wires those: libgalaxy_va,
/// galaxy-pe)
pub const gpu_convert = @import("gpu_convert.sig");
pub const enc_rgb = @import("enc_rgb.sig");
pub const vpx_dsl = @import("vpx_dsl.sig");
pub const vpx_bool = @import("vpx_bool.sig");
pub const vp8_kernels = @import("vp8_kernels.sig");
pub const enc_vp8 = @import("enc_vp8.sig");
pub const vp9_kernels = @import("vp9_kernels.sig");
pub const enc_vp9 = @import("enc_vp9.sig");

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
    _ = enc_rc;
    _ = enc_parse;
    _ = enc_av1;
    _ = convert;
    _ = driver;
    _ = @import("driver_test.sig");
    _ = @import("driver_10bit_test.sig");
    _ = @import("hevc_stream_test.sig");
    _ = @import("h264_stream_test.sig");
    _ = @import("video_test.sig");
    _ = @import("hevc_parse_test.sig");
    _ = @import("enc_test.sig");
    _ = enc_import;
    _ = vpx_dsl;
    _ = vpx_bool;
    _ = vp8_kernels;
    _ = enc_vp8;
    _ = vp9_kernels;
    _ = @import("vp9_tx.sig");
    _ = @import("vp9_enc_tables.sig");
    _ = enc_vp9;
    _ = @import("enc_vpx.sig");
    _ = @import("vpx_driver_test.sig");
}
