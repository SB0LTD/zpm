//! Focused numerical GPU contracts; kernels skip when CUDA is unavailable.
test {
    _ = @import("whisper/kernels_test.sig");
    _ = @import("whisper/decoder_test.sig");
    _ = @import("whisper/gpu_test.sig");
}
