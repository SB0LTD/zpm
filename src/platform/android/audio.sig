// Microphone and call recording for Android
// Layer 1: Platform (Android)
//
// Abstracts Android's AudioRecord for ambient recording and call audio
// capture (both streams). Outputs PCM buffers for downstream encoding.

const std = @import("std");

/// Audio source selection.
pub const AudioSource = enum {
    /// Microphone for ambient recording.
    microphone,
    /// Voice uplink (caller's voice during a call).
    voice_uplink,
    /// Voice downlink (remote party's voice during a call).
    voice_downlink,
    /// Both call streams mixed.
    voice_call,
    /// Voice recognition optimized source.
    voice_recognition,
};

/// Audio format parameters.
pub const AudioFormat = struct {
    /// Sample rate in Hz (typically 16000 or 44100).
    sample_rate: u32 = 16000,
    /// Number of channels (1 = mono, 2 = stereo).
    channels: u8 = 1,
    /// Bits per sample (16 or 24).
    bits_per_sample: u8 = 16,

    /// Calculate bytes per second for this format.
    pub fn bytesPerSecond(self: *const AudioFormat) u32 {
        return self.sample_rate * @as(u32, self.channels) * (@as(u32, self.bits_per_sample) / 8);
    }

    /// Calculate bytes per 5-second segment.
    pub fn bytesPerSegment(self: *const AudioFormat) u32 {
        return self.bytesPerSecond() * 5;
    }

    /// Calculate buffer size in bytes for a given duration in milliseconds.
    pub fn bufferSizeForMs(self: *const AudioFormat, duration_ms: u32) u32 {
        return (self.bytesPerSecond() * duration_ms) / 1000;
    }
};

/// Recording session state.
pub const RecordingState = enum {
    idle,
    initializing,
    recording,
    paused,
    stopping,
    error_state,
};

/// Error codes for audio recording.
pub const AudioError = enum {
    none,
    permission_denied,
    hardware_unavailable,
    invalid_source,
    buffer_overflow,
    io_error,
    interrupted,
};

/// PCM buffer output from recording.
pub const PcmBuffer = struct {
    /// Raw PCM data.
    data: [*]u8,
    /// Length of valid data in bytes.
    len: u32,
    /// Timestamp of buffer start in UTC milliseconds.
    timestamp_ms: u64,
    /// Duration of audio in this buffer in milliseconds.
    duration_ms: u32,
    /// Format of the PCM data.
    format: AudioFormat,
};

/// Callback for PCM data delivery.
pub const PcmCallback = *const fn (buffer: *const PcmBuffer, ctx: *anyopaque) void;

/// Callback for recording errors.
pub const ErrorCallback = *const fn (err: AudioError, ctx: *anyopaque) void;

/// Audio recorder configuration.
pub const RecorderConfig = struct {
    source: AudioSource = .microphone,
    format: AudioFormat = .{},
    /// Buffer delivery interval in milliseconds.
    delivery_interval_ms: u32 = 5000,
    /// Maximum recording duration in seconds (0 = unlimited).
    max_duration_secs: u32 = 0,
};

/// Audio recorder controller.
pub const AudioRecorder = struct {
    config: RecorderConfig,
    state: RecordingState,
    on_pcm: PcmCallback,
    on_error: ?ErrorCallback,
    context: *anyopaque,
    /// Start timestamp of current recording.
    start_time_ms: u64,
    /// Total bytes recorded in this session.
    total_bytes: u64,
    /// Total duration recorded in milliseconds.
    total_duration_ms: u64,
    /// Last error encountered.
    last_error: AudioError,

    pub fn init(
        config: RecorderConfig,
        on_pcm: PcmCallback,
        context: *anyopaque,
    ) AudioRecorder {
        return .{
            .config = config,
            .state = .idle,
            .on_pcm = on_pcm,
            .on_error = null,
            .context = context,
            .start_time_ms = 0,
            .total_bytes = 0,
            .total_duration_ms = 0,
            .last_error = .none,
        };
    }

    /// Begin recording.
    pub fn start(self: *AudioRecorder, current_time_ms: u64) void {
        self.state = .recording;
        self.start_time_ms = current_time_ms;
        self.total_bytes = 0;
        self.total_duration_ms = 0;
    }

    /// Stop recording.
    pub fn stop(self: *AudioRecorder) void {
        self.state = .stopping;
    }

    /// Pause recording (keep hardware initialized).
    pub fn pause(self: *AudioRecorder) void {
        if (self.state == .recording) {
            self.state = .paused;
        }
    }

    /// Resume from pause.
    pub fn resume(self: *AudioRecorder) void {
        if (self.state == .paused) {
            self.state = .recording;
        }
    }

    /// Process an incoming PCM buffer from the hardware.
    pub fn onBufferReady(self: *AudioRecorder, buffer: *const PcmBuffer) void {
        if (self.state != .recording) return;
        self.total_bytes += buffer.len;
        self.total_duration_ms += buffer.duration_ms;
        self.on_pcm(buffer, self.context);

        // Check max duration
        if (self.config.max_duration_secs > 0) {
            if (self.total_duration_ms >= @as(u64, self.config.max_duration_secs) * 1000) {
                self.stop();
            }
        }
    }

    /// Report an error from the hardware layer.
    pub fn onError(self: *AudioRecorder, err: AudioError) void {
        self.last_error = err;
        self.state = .error_state;
        if (self.on_error) |cb| {
            cb(err, self.context);
        }
    }

    /// Check if recording has exceeded max duration.
    pub fn isExpired(self: *const AudioRecorder) bool {
        if (self.config.max_duration_secs == 0) return false;
        return self.total_duration_ms >= @as(u64, self.config.max_duration_secs) * 1000;
    }
};
