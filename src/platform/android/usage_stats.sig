// App usage statistics for Android
// Layer 1: Platform (Android)
//
// Wraps Android's UsageStatsManager for detecting foreground app transitions
// and tracking session start/end timestamps.

const std = @import("std");

/// A single app usage event (foreground transition).
pub const UsageEvent = struct {
    /// Package name of the app.
    package_name: [256]u8 = std.mem.zeroes([256]u8),
    package_name_len: u8 = 0,
    /// Display name (activity label).
    display_name: [128]u8 = std.mem.zeroes([128]u8),
    display_name_len: u8 = 0,
    /// Event type.
    event_type: EventType = .move_to_foreground,
    /// Timestamp of the event in UTC milliseconds.
    timestamp_ms: u64 = 0,

    pub const EventType = enum {
        move_to_foreground,
        move_to_background,
        configuration_change,
        user_interaction,
        shortcut_invocation,
    };

    pub fn getPackageName(self: *const UsageEvent) []const u8 {
        return self.package_name[0..self.package_name_len];
    }

    pub fn getDisplayName(self: *const UsageEvent) []const u8 {
        return self.display_name[0..self.display_name_len];
    }
};

/// A completed app usage session.
pub const UsageSession = struct {
    /// Package name.
    package_name: [256]u8 = std.mem.zeroes([256]u8),
    package_name_len: u8 = 0,
    /// Display name.
    display_name: [128]u8 = std.mem.zeroes([128]u8),
    display_name_len: u8 = 0,
    /// Session start time in UTC milliseconds.
    start_ms: u64 = 0,
    /// Session end time in UTC milliseconds.
    end_ms: u64 = 0,
    /// Whether session was interrupted (reboot/crash).
    interrupted: bool = false,

    /// Duration of the session in seconds.
    pub fn durationSecs(self: *const UsageSession) u32 {
        if (self.end_ms <= self.start_ms) return 0;
        return @intCast((self.end_ms - self.start_ms) / 1000);
    }

    /// Duration in milliseconds.
    pub fn durationMs(self: *const UsageSession) u64 {
        if (self.end_ms <= self.start_ms) return 0;
        return self.end_ms - self.start_ms;
    }

    /// Check if session is shorter than minimum threshold (1 second).
    pub fn isTooShort(self: *const UsageSession) bool {
        return self.durationMs() < 1000;
    }

    pub fn getPackageName(self: *const UsageSession) []const u8 {
        return self.package_name[0..self.package_name_len];
    }
};

/// Callback for foreground app change.
pub const TransitionCallback = *const fn (session: *const UsageSession, ctx: *anyopaque) void;

/// Usage stats tracker — detects foreground transitions and tracks sessions.
pub const UsageTracker = struct {
    on_session_end: TransitionCallback,
    context: *anyopaque,
    /// Currently active foreground app.
    current_app: [256]u8,
    current_app_len: u8,
    current_display: [128]u8,
    current_display_len: u8,
    /// Timestamp when current app came to foreground.
    current_start_ms: u64,
    /// Whether we have an active foreground session.
    has_active_session: bool,
    /// Queue of completed sessions pending flush.
    pending_sessions: [500]UsageSession,
    pending_count: u16,
    /// Last flush timestamp.
    last_flush_ms: u64,
    /// Flush interval in milliseconds (default 15 minutes).
    flush_interval_ms: u64,

    pub fn init(callback: TransitionCallback, context: *anyopaque) UsageTracker {
        return .{
            .on_session_end = callback,
            .context = context,
            .current_app = std.mem.zeroes([256]u8),
            .current_app_len = 0,
            .current_display = std.mem.zeroes([128]u8),
            .current_display_len = 0,
            .current_start_ms = 0,
            .has_active_session = false,
            .pending_sessions = undefined,
            .pending_count = 0,
            .last_flush_ms = 0,
            .flush_interval_ms = 900_000, // 15 minutes
        };
    }

    /// Process a foreground transition event.
    pub fn onEvent(self: *UsageTracker, event: *const UsageEvent) void {
        switch (event.event_type) {
            .move_to_foreground => {
                // Close previous session if any
                if (self.has_active_session) {
                    self.closeCurrentSession(event.timestamp_ms, false);
                }
                // Start new session
                const pkg = event.getPackageName();
                @memcpy(self.current_app[0..pkg.len], pkg);
                self.current_app_len = @intCast(pkg.len);
                const display = event.getDisplayName();
                @memcpy(self.current_display[0..display.len], display);
                self.current_display_len = @intCast(display.len);
                self.current_start_ms = event.timestamp_ms;
                self.has_active_session = true;
            },
            .move_to_background => {
                if (self.has_active_session) {
                    self.closeCurrentSession(event.timestamp_ms, false);
                }
            },
            else => {},
        }
    }

    /// Close the current session and add to pending queue.
    fn closeCurrentSession(self: *UsageTracker, end_ms: u64, interrupted: bool) void {
        var session: UsageSession = .{
            .start_ms = self.current_start_ms,
            .end_ms = end_ms,
            .interrupted = interrupted,
        };
        @memcpy(session.package_name[0..self.current_app_len], self.current_app[0..self.current_app_len]);
        session.package_name_len = self.current_app_len;
        @memcpy(session.display_name[0..self.current_display_len], self.current_display[0..self.current_display_len]);
        session.display_name_len = self.current_display_len;

        // Only record if session is long enough (>= 1 second)
        if (!session.isTooShort()) {
            if (self.pending_count < 500) {
                self.pending_sessions[self.pending_count] = session;
                self.pending_count += 1;
            }
            self.on_session_end(&session, self.context);
        }

        self.has_active_session = false;
    }

    /// Force-close current session on interruption (reboot/crash).
    pub fn onInterruption(self: *UsageTracker, timestamp_ms: u64) void {
        if (self.has_active_session) {
            self.closeCurrentSession(timestamp_ms, true);
        }
    }

    /// Check if pending queue should be flushed.
    pub fn shouldFlush(self: *const UsageTracker, current_ms: u64) bool {
        if (self.pending_count >= 500) return true;
        if (self.last_flush_ms == 0) return self.pending_count > 0;
        return (current_ms - self.last_flush_ms) >= self.flush_interval_ms and self.pending_count > 0;
    }

    /// Mark pending sessions as flushed.
    pub fn markFlushed(self: *UsageTracker, current_ms: u64) void {
        self.pending_count = 0;
        self.last_flush_ms = current_ms;
    }
};
