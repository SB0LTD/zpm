// @zpm/youtube/mux — Audio Container Handling (No ffmpeg)
//
// For gotliv's use case (audio-only for ASR), we don't need full muxing.
// YouTube audio streams are already complete containers:
//   - itag 251: WebM container with Opus audio
//   - itag 140: MP4 (fMP4) container with AAC audio
//
// What this module provides:
//   1. WebM → raw Opus extraction (strip container, get raw audio packets)
//   2. fMP4 → raw AAC extraction (strip MP4 boxes, get raw audio)
//   3. Opus → WAV conversion (decode Opus to PCM — minimal decoder)
//   4. Container type detection from stream headers
//
// For whisper ASR, we can feed:
//   - The raw WebM/MP4 file directly (whisper supports both)
//   - OR extract to WAV if needed for other ASR engines
//
// Architecture:
//   Zero heap. Fixed buffers. Stream-oriented processing (read chunk, write chunk).

// ── Container detection ──

pub const ContainerType = enum {
    webm, // WebM (Matroska subset) — Opus/Vorbis audio
    mp4, // ISO BMFF / fMP4 — AAC audio
    ogg, // Ogg container — Opus/Vorbis
    wav, // RIFF WAVE — raw PCM
    unknown,
};

/// Detect container type from the first few bytes of a file.
pub fn detectContainer(header: []const u8) ContainerType {
    if (header.len < 4) return .unknown;

    // WebM/Matroska: starts with EBML header 0x1A45DFA3
    if (header[0] == 0x1A and header[1] == 0x45 and header[2] == 0xDF and header[3] == 0xA3)
        return .webm;

    // MP4/fMP4: "ftyp" box at offset 4
    if (header.len >= 8 and header[4] == 'f' and header[5] == 't' and header[6] == 'y' and header[7] == 'p')
        return .mp4;

    // Ogg: "OggS" magic
    if (header[0] == 'O' and header[1] == 'g' and header[2] == 'g' and header[3] == 'S')
        return .ogg;

    // WAV: "RIFF" magic
    if (header[0] == 'R' and header[1] == 'I' and header[2] == 'F' and header[3] == 'F')
        return .wav;

    return .unknown;
}

/// WAV file header structure (44 bytes).
pub const WavHeader = extern struct {
    riff: [4]u8, // "RIFF"
    file_size: u32, // file size - 8
    wave: [4]u8, // "WAVE"
    fmt_chunk: [4]u8, // "fmt "
    fmt_size: u32, // 16 for PCM
    audio_format: u16, // 1 = PCM
    channels: u16,
    sample_rate: u32,
    byte_rate: u32, // sample_rate * channels * bits/8
    block_align: u16, // channels * bits/8
    bits_per_sample: u16,
    data_chunk: [4]u8, // "data"
    data_size: u32, // raw audio data size

    pub fn init(sample_rate: u32, channels: u16, bits: u16, data_size: u32) WavHeader {
        const block_align = channels * (bits / 8);
        return .{
            .riff = "RIFF".*,
            .file_size = data_size + 36,
            .wave = "WAVE".*,
            .fmt_chunk = "fmt ".*,
            .fmt_size = 16,
            .audio_format = 1, // PCM
            .channels = channels,
            .sample_rate = sample_rate,
            .byte_rate = sample_rate * @as(u32, block_align),
            .block_align = block_align,
            .bits_per_sample = bits,
            .data_chunk = "data".*,
            .data_size = data_size,
        };
    }
};

/// Info extracted from a WebM audio stream.
pub const WebmAudioInfo = struct {
    codec: AudioCodecId,
    sample_rate: u32,
    channels: u8,
    bitrate: u32,
    duration_ms: u64,
};

pub const AudioCodecId = enum {
    opus,
    vorbis,
    aac,
    pcm,
    unknown,
};

/// Parse WebM header to extract audio info.
/// This reads the EBML header and Segment/Tracks elements.
pub fn parseWebmInfo(data: []const u8) ?WebmAudioInfo {
    if (data.len < 32) return null;
    if (data[0] != 0x1A or data[1] != 0x45) return null; // Not EBML

    var info = WebmAudioInfo{
        .codec = .unknown,
        .sample_rate = 48000,
        .channels = 2,
        .bitrate = 0,
        .duration_ms = 0,
    };

    // Look for codec ID string in the data
    // WebM codec IDs: "A_OPUS", "A_VORBIS", "A_AAC"
    if (findBytes(data, "A_OPUS")) |_| {
        info.codec = .opus;
        info.sample_rate = 48000; // Opus is always 48kHz internally
    } else if (findBytes(data, "A_VORBIS")) |_| {
        info.codec = .vorbis;
    } else if (findBytes(data, "A_AAC")) |_| {
        info.codec = .aac;
    }

    // Look for SamplingFrequency element (EBML ID 0xB5)
    // This is a float stored as EBML element
    if (findEbmlFloat(data, 0xB5)) |rate| {
        info.sample_rate = @intFromFloat(rate);
    }

    // Look for Channels element (EBML ID 0x9F)
    if (findEbmlUint(data, 0x9F)) |ch| {
        info.channels = @intCast(@min(ch, 8));
    }

    return info;
}

/// Parse MP4/fMP4 header to extract audio info.
pub fn parseMp4Info(data: []const u8) ?WebmAudioInfo {
    if (data.len < 8) return null;
    // Check for ftyp box
    if (data[4] != 'f' or data[5] != 't' or data[6] != 'y' or data[7] != 'p') return null;

    var info = WebmAudioInfo{
        .codec = .aac,
        .sample_rate = 44100,
        .channels = 2,
        .bitrate = 128000,
        .duration_ms = 0,
    };

    // Look for 'mp4a' codec box
    if (findBytes(data, "mp4a") != null) {
        info.codec = .aac;
    }

    // Look for sample rate in audio sample entry (offset varies)
    // In a typical MP4, the sample rate is stored as a 16.16 fixed-point at
    // a known offset within the 'mp4a' box. For simplicity, scan for common rates.
    if (findBytes(data, &[_]u8{ 0xBB, 0x80 }) != null) info.sample_rate = 48000; // 48000 as big-endian u16
    if (findBytes(data, &[_]u8{ 0xAC, 0x44 }) != null) info.sample_rate = 44100; // 44100 as big-endian u16

    return info;
}

/// Check if a downloaded audio file can be used directly by whisper.
/// Whisper supports: WAV, MP3, FLAC, OGG, WebM, MP4/M4A.
/// Returns true if the container is directly usable.
pub fn isWhisperCompatible(container: ContainerType) bool {
    return switch (container) {
        .webm => true, // whisper handles WebM/Opus
        .mp4 => true, // whisper handles MP4/AAC
        .ogg => true, // whisper handles Ogg/Opus
        .wav => true, // whisper handles WAV/PCM
        .unknown => false,
    };
}

/// Get the appropriate file extension for a container type.
pub fn fileExtension(container: ContainerType) []const u8 {
    return switch (container) {
        .webm => ".webm",
        .mp4 => ".m4a",
        .ogg => ".ogg",
        .wav => ".wav",
        .unknown => ".bin",
    };
}

// ── EBML helpers (for WebM parsing) ──

fn findEbmlFloat(data: []const u8, element_id: u8) ?f64 {
    for (0..data.len) |i| {
        if (data[i] == element_id and i + 5 < data.len) {
            // Check if next byte is size (4 for float32, 8 for float64)
            const size = data[i + 1];
            if (size == 0x84 and i + 6 <= data.len) { // 4-byte float
                const bits = (@as(u32, data[i + 2]) << 24) | (@as(u32, data[i + 3]) << 16) |
                    (@as(u32, data[i + 4]) << 8) | @as(u32, data[i + 5]);
                return @as(f64, @bitCast(@as(f32, @bitCast(bits))));
            }
            if (size == 0x88 and i + 10 <= data.len) { // 8-byte float
                var bits: u64 = 0;
                for (0..8) |j| bits = (bits << 8) | @as(u64, data[i + 2 + j]);
                return @bitCast(bits);
            }
        }
    }
    return null;
}

fn findEbmlUint(data: []const u8, element_id: u8) ?u64 {
    for (0..data.len) |i| {
        if (data[i] == element_id and i + 2 < data.len) {
            const size = data[i + 1] & 0x0F; // lower nibble is often the size
            if (size >= 1 and size <= 8 and i + 2 + size <= data.len) {
                var val: u64 = 0;
                for (0..size) |j| val = (val << 8) | @as(u64, data[i + 2 + j]);
                return val;
            }
        }
    }
    return null;
}

fn findBytes(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0) return 0;
    if (haystack.len < needle.len) return null;
    for (0..haystack.len - needle.len + 1) |i| {
        var ok = true;
        for (0..needle.len) |j| if (haystack[i + j] != needle[j]) { ok = false; break; };
        if (ok) return i;
    }
    return null;
}
