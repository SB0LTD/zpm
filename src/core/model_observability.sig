//! @zpm/model-observability — bounded, replayable multimodal execution trace.
//!
//! The trace contains timing and resource metadata only: prompts, audio, pixels,
//! and generated content never enter this store.  A fixed ring keeps the hot
//! path allocation-free while per-stage logarithmic histograms retain useful
//! latency distributions after detailed events are overwritten.

const std = @import("std");

pub const Stage = enum(u8) {
    request_submit,
    request_claim,
    scheduler_queue,
    executor_begin,
    text_input,
    visual_snapshot,
    vision_patch,
    vision_projector,
    audio_irq_ack,
    audio_capture_complete,
    audio_features,
    model_prefill,
    model_decode,
    model_slice,
    now_projection,
    now_fusion,
    ui_plan,
    tts_frontend,
    tts_codec,
    audio_playback_submit,
    audio_playback_complete,
    display_queue_submit,
    display_queue_complete,
    display_present,
    cancellation,
    completion,
    // Appended after v1's original terminal tag so existing numeric stage IDs
    // remain stable for previously captured records.
    display_irq_ack,
};

pub const STAGE_COUNT: usize = @intFromEnum(Stage.display_irq_ack) + 1;
pub const HISTOGRAM_BUCKETS: usize = 64;

pub const Modality = enum(u8) {
    system,
    text,
    vision,
    audio,
    speech,
    synthesis,
    display,
};

pub const Direction = enum(u8) {
    internal,
    device_to_kernel,
    kernel_to_device,
    model_to_now,
    now_to_ui,
};

pub const Status = enum(u8) {
    ok,
    pending,
    rejected,
    deadline,
    cancelled,
    invalid,
    device_failure,
    numerical_failure,
};

pub const Flags = packed struct(u16) {
    interrupt_observed: bool = false,
    polling_fallback: bool = false,
    final_chunk: bool = false,
    neural: bool = false,
    replay_gap: bool = false,
    _reserved: u11 = 0,
};

/// Canonical wire record returned by the SB0 debug-trace ABI.  The layout is
/// exactly 64 bytes and contains no pointers, padding-dependent data, or text.
pub const TraceEvent = extern struct {
    sequence: u64 = 0,
    correlation_id: u64 = 0,
    timestamp_tick: u64 = 0,
    duration_ticks: u64 = 0,
    bytes: u64 = 0,
    work_units: u64 = 0,
    model_tag: u64 = 0,
    queue_depth: u16 = 0,
    stage: Stage = .request_submit,
    direction: Direction = .internal,
    status: Status = .ok,
    modality: Modality = .system,
    flags: Flags = .{},
};

pub const EventInput = struct {
    correlation_id: u64 = 0,
    timestamp_tick: u64,
    duration_ticks: u64 = 0,
    bytes: u64 = 0,
    work_units: u64 = 0,
    model_tag: u64 = 0,
    queue_depth: u16 = 0,
    stage: Stage,
    direction: Direction = .internal,
    status: Status = .ok,
    modality: Modality = .system,
    flags: Flags = .{},
};

pub const StageStats = struct {
    count: u64 = 0,
    failures: u64 = 0,
    total_duration_ticks: u64 = 0,
    maximum_duration_ticks: u64 = 0,
    total_bytes: u64 = 0,
    total_work_units: u64 = 0,
    histogram: [HISTOGRAM_BUCKETS]u64 = @splat(0),

    /// Nearest-rank quantile upper bound from power-of-two buckets.  It is an
    /// explicit conservative estimate, never presented as an exact sample.
    pub fn quantileUpperBound(self: *const StageStats, numerator: u32, denominator: u32) ?u64 {
        if (self.count == 0 or denominator == 0 or numerator == 0 or numerator > denominator)
            return null;
        const scaled = @mulWithOverflow(self.count, @as(u64, numerator));
        const product = if (scaled[1] == 0) scaled[0] else std.math.maxInt(u64);
        const rank = @max(@as(u64, 1), product / denominator + @intFromBool(product % denominator != 0));
        var cumulative: u64 = 0;
        for (self.histogram, 0..) |count, bucket| {
            cumulative +|= count;
            if (cumulative >= rank) return bucketUpperBound(bucket);
        }
        return self.maximum_duration_ticks;
    }
};

pub const Cursor = struct { next_sequence: u64 = 1 };

pub const DeltaReceipt = struct {
    copied: usize = 0,
    next_sequence: u64 = 1,
    oldest_available: u64 = 0,
    latest_available: u64 = 0,
    gap_detected: bool = false,
};

pub const Summary = struct {
    next_sequence: u64,
    events_retained: usize,
    events_overwritten: u64,
    invalid_flag_events: u64,
};

pub fn Trace(comptime capacity: usize) type {
    if (capacity == 0) @compileError("trace capacity must be non-zero");
    return struct {
        const Self = @This();

        events: [capacity]TraceEvent = @splat(.{}),
        start: usize = 0,
        len: usize = 0,
        // Zero keeps a global trace in true BSS; the first record installs 1.
        next_sequence: u64 = 0,
        events_overwritten: u64 = 0,
        invalid_flag_events: u64 = 0,
        stages: [STAGE_COUNT]StageStats = @splat(.{}),

        pub fn staticBytes() usize { return @sizeOf(Self); }

        pub fn record(self: *Self, input: EventInput) u64 {
            if (input.flags._reserved != 0) {
                self.invalid_flag_events +|= 1;
                return 0;
            }
            if (self.next_sequence == 0) self.next_sequence = 1;
            const sequence = self.next_sequence;
            self.next_sequence +%= 1;
            if (self.next_sequence == 0) self.next_sequence = 1;

            const event = TraceEvent{
                .sequence = sequence,
                .correlation_id = input.correlation_id,
                .timestamp_tick = input.timestamp_tick,
                .duration_ticks = input.duration_ticks,
                .bytes = input.bytes,
                .work_units = input.work_units,
                .model_tag = input.model_tag,
                .queue_depth = input.queue_depth,
                .stage = input.stage,
                .direction = input.direction,
                .status = input.status,
                .modality = input.modality,
                .flags = input.flags,
            };
            if (self.len < capacity) {
                self.events[(self.start + self.len) % capacity] = event;
                self.len += 1;
            } else {
                self.events[self.start] = event;
                self.start = (self.start + 1) % capacity;
                self.events_overwritten +|= 1;
            }
            self.updateStage(event);
            return sequence;
        }

        pub fn readDelta(self: *const Self, cursor: *Cursor, output: []TraceEvent) DeltaReceipt {
            var receipt = DeltaReceipt{ .next_sequence = cursor.next_sequence };
            if (self.len == 0) return receipt;
            const oldest = self.at(0).?.sequence;
            const latest = self.at(self.len - 1).?.sequence;
            receipt.oldest_available = oldest;
            receipt.latest_available = latest;
            var wanted = if (cursor.next_sequence == 0) oldest else cursor.next_sequence;
            if (wanted < oldest) {
                wanted = oldest;
                receipt.gap_detected = true;
            }
            for (0..self.len) |index| {
                if (receipt.copied == output.len) break;
                const event = self.at(index).?.*;
                if (event.sequence < wanted) continue;
                output[receipt.copied] = event;
                receipt.copied += 1;
                wanted = event.sequence +| 1;
            }
            cursor.next_sequence = wanted;
            receipt.next_sequence = wanted;
            return receipt;
        }

        pub fn stageStats(self: *const Self, stage: Stage) *const StageStats {
            return &self.stages[@intFromEnum(stage)];
        }

        pub fn summary(self: *const Self) Summary {
            return .{
                .next_sequence = self.next_sequence,
                .events_retained = self.len,
                .events_overwritten = self.events_overwritten,
                .invalid_flag_events = self.invalid_flag_events,
            };
        }

        fn at(self: *const Self, index: usize) ?*const TraceEvent {
            if (index >= self.len) return null;
            return &self.events[(self.start + index) % capacity];
        }

        fn updateStage(self: *Self, event: TraceEvent) void {
            const stats = &self.stages[@intFromEnum(event.stage)];
            stats.count +|= 1;
            if (event.status != .ok and event.status != .pending) stats.failures +|= 1;
            stats.total_duration_ticks +|= event.duration_ticks;
            stats.maximum_duration_ticks = @max(stats.maximum_duration_ticks, event.duration_ticks);
            stats.total_bytes +|= event.bytes;
            stats.total_work_units +|= event.work_units;
            stats.histogram[histogramBucket(event.duration_ticks)] +|= 1;
        }
    };
}

fn histogramBucket(value: u64) usize {
    if (value == 0) return 0;
    // One count-leading-zeros operation replaces a value-dependent loop. The
    // bucket is floor(log2(value))+1, saturated into the final overflow bin.
    const bits: usize = @as(usize, @bitSizeOf(u64)) - @clz(value);
    return @min(bits, HISTOGRAM_BUCKETS - 1);
}

fn bucketUpperBound(bucket: usize) u64 {
    if (bucket == 0) return 0;
    if (bucket >= 63) return std.math.maxInt(u64);
    return (@as(u64, 1) << @intCast(bucket)) - 1;
}

comptime {
    if (@sizeOf(TraceEvent) != 64) @compileError("TraceEvent ABI must remain 64 bytes");
}

test "trace replay detects overwrite gaps and preserves correlation" {
    var trace = Trace(3){};
    for (1..6) |sequence| _ = trace.record(.{
        .timestamp_tick = sequence * 10,
        .correlation_id = sequence,
        .stage = .model_slice,
        .duration_ticks = sequence,
        .modality = .text,
    });
    var cursor = Cursor{ .next_sequence = 1 };
    var output: [2]TraceEvent = undefined;
    const first = trace.readDelta(&cursor, &output);
    try std.testing.expect(first.gap_detected);
    try std.testing.expectEqual(@as(usize, 2), first.copied);
    try std.testing.expectEqual(@as(u64, 3), output[0].sequence);
    try std.testing.expectEqual(@as(u64, 4), output[1].correlation_id);
    const second = trace.readDelta(&cursor, &output);
    try std.testing.expect(!second.gap_detected);
    try std.testing.expectEqual(@as(usize, 1), second.copied);
    try std.testing.expectEqual(@as(u64, 5), output[0].sequence);
}

test "stage histograms retain conservative p50 p95 and failure totals" {
    var trace = Trace(8){};
    const durations = [_]u64{ 0, 1, 2, 3, 8, 9 };
    for (durations, 0..) |duration, index| _ = trace.record(.{
        .timestamp_tick = index,
        .stage = .vision_projector,
        .duration_ticks = duration,
        .status = if (index == 5) .deadline else .ok,
    });
    const stats = trace.stageStats(.vision_projector);
    try std.testing.expectEqual(@as(u64, 6), stats.count);
    try std.testing.expectEqual(@as(u64, 1), stats.failures);
    try std.testing.expectEqual(@as(u64, 23), stats.total_duration_ticks);
    try std.testing.expectEqual(@as(u64, 3), stats.quantileUpperBound(1, 2).?);
    try std.testing.expectEqual(@as(u64, 15), stats.quantileUpperBound(95, 100).?);
}

test "wire event and trace memory are exact fixed-capacity values" {
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(TraceEvent));
    const Tiny = Trace(4);
    try std.testing.expectEqual(@sizeOf(Tiny), Tiny.staticBytes());
}
