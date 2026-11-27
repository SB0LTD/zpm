//! Standalone focused native Whisper decoder/kernel test entry point.
test {
    _ = @import("whisper/kernels_test.sig");
    _ = @import("whisper/decoder_test.sig");
    _ = @import("whisper/gpu_test.sig");
}
