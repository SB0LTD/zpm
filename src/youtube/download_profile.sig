// Opt-in, caller-owned wall-clock profiling for native YouTube downloads.
// Nested timings overlap: VM/exchange are inside tokens; HTTP/UMP/sink/sleep
// are inside transfer. UMP includes sink time. No clocks run when disabled.
extern "kernel32" fn QueryPerformanceCounter(*i64) c_int;
extern "kernel32" fn QueryPerformanceFrequency(*i64) c_int;
var frequency: u64 = 0;

pub const Sample = struct {
    http_ns: u64 = 0,
    response_bytes: u64 = 0,
    media_bytes: u64 = 0,
    status: u32 = 0,
    protection: i32 = 0, // per-response update; zero means no update
};
pub const Profile = struct {
    total_ns: u64 = 0,
    tokens_ns: u64 = 0,
    vm_ns: u64 = 0,
    exchange_ns: u64 = 0,
    player_ns: u64 = 0,
    transfer_ns: u64 = 0,
    request_build_ns: u64 = 0,
    http_ns: u64 = 0,
    ump_ns: u64 = 0,
    sink_ns: u64 = 0,
    sleep_ns: u64 = 0,
    commit_ns: u64 = 0,
    first_media_ns: u64 = 0, // from operation start, including setup
    http_requests: u32 = 0,
    response_bytes: u64 = 0, // UMP HTTP body bytes, not TLS/wire bytes
    sample_count: usize = 0,
    dropped_samples: u32 = 0,
    samples: [2048]Sample = undefined,
    started_ns: u64 = 0,

    pub fn recordHttp(self: *Profile, duration: u64, bytes: usize, status: u32) void {
        self.http_ns += duration;
        self.http_requests += 1;
        self.response_bytes += bytes;
        if (self.sample_count < self.samples.len) {
            self.samples[self.sample_count] = .{ .http_ns = duration, .response_bytes = bytes, .status = status };
            self.sample_count += 1;
        } else self.dropped_samples += 1;
    }
};

pub fn clock(profile: ?*Profile) u64 {
    if (profile == null) return 0;
    if (frequency == 0) {
        var value: i64 = 0;
        if (QueryPerformanceFrequency(&value) == 0 or value <= 0) return 0;
        frequency = @intCast(value);
    }
    var value: i64 = 0;
    if (QueryPerformanceCounter(&value) == 0 or value < 0) return 0;
    return @intCast(@as(u128, @intCast(value)) * 1_000_000_000 / frequency);
}
pub fn add(profile: ?*Profile, comptime field: []const u8, started: u64) void {
    if (profile) |p| @field(p, field) += clock(p) -| started;
}

test "profile: bounded samples retain aggregate counts after overflow" {
    const testing = @import("std").testing;
    var p = Profile{};
    for (0..p.samples.len + 3) |_| p.recordHttp(7, 11, 200);
    try testing.expectEqual(p.samples.len, p.sample_count);
    try testing.expectEqual(@as(u32, 3), p.dropped_samples);
    try testing.expectEqual(@as(u32, @intCast(p.samples.len + 3)), p.http_requests);
    try testing.expectEqual(@as(u64, (p.samples.len + 3) * 7), p.http_ns);
    try testing.expectEqual(@as(u64, (p.samples.len + 3) * 11), p.response_bytes);
    try testing.expectEqual(@as(u64, 0), clock(null));
}
