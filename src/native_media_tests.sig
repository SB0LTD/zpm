//! Portable codec, recognition and transcript contracts. Driver-backed
//! contracts have a separate entry point in whisper_gpu_test.sig.
test {
    _ = @import("audio/wav.sig");
}
test {
    _ = @import("audio/resample.sig");
}
test {
    _ = @import("audio/mp4.sig");
}
test {
    _ = @import("audio/aac.sig");
}
test {
    _ = @import("whisper/model.sig");
}
test {
    _ = @import("whisper/tokenizer.sig");
}
test {
    _ = @import("whisper/decoding.sig");
}
test {
    _ = @import("whisper/encoder.sig");
}
test {
    _ = @import("whisper/kernels_test.sig");
}
test {
    _ = @import("whisper/decoder_test.sig");
}
test {
    _ = @import("transcript/asr_import.sig");
}
test {
    _ = @import("transcript/tests.sig");
}
test {
    _ = @import("transcript/render.sig");
}
test {
    _ = @import("core/windows_arguments.sig");
}
test {
    _ = @import("llm/prefix_cache.sig");
}
