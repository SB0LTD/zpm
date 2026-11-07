//! Focused numerical GPU contracts; kernels skip when CUDA is unavailable.
test {
    // The current CUDA loader uses Windows APIs. Portable CPU contracts are
    // also collected by native_media_tests.sig on all supported hosts.
    if (comptime @import("builtin").os.tag == .windows) {
        _ = @import("whisper/kernels_test.sig");
        _ = @import("whisper/decoder_test.sig");
        _ = @import("whisper/gpu_test.sig");
    } else return error.SkipZigTest;
}
