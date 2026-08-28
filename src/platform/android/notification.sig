// NotificationListenerService abstraction for Android
// Layer 1: Platform (Android)
//
// Wraps Android's NotificationListenerService to capture notification
// title, body, package name, and timestamp from all apps.

const std = @import("std");

/// Captured notification data.
pub const CapturedNotification = struct {
    /// Notification title (up to 256 chars).
    title: [256]u8 = std.mem.zeroes([256]u8),
    title_len: u8 = 0,
    /// Notification body (up to 4096 chars).
    body: [4096]u8 = std.mem.zeroes([4096]u8),
    body_len: u16 = 0,
    /// Source package name.
    package_name: [256]u8 = std.mem.zeroes([256]u8),
    package_name_len: u8 = 0,
    /// Timestamp when notification was posted.
    timestamp_ms: u64 = 0,
    /// Notification key for deduplication.
    key: [128]u8 = std.mem.zeroes([128]u8),
    key_len: u8 = 0,
    /// Whether notification is ongoing (persistent).
    is_ongoing: bool = false,
    /// Priority level.
    priority: Priority = .default_,

    pub const Priority = enum {
        min,
        low,
        default_,
        high,
        max,
    };

    pub fn getTitle(self: *const CapturedNotification) []const u8 {
        return self.title[0..self.title_len];
    }

    pub fn getBody(self: *const CapturedNotification) []const u8 {
        return self.body[0..self.body_len];
    }

    pub fn getPackageName(self: *const CapturedNotification) []const u8 {
        return self.package_name[0..self.package_name_len];
    }
};

/// Callback for notification events.
pub const NotificationCallback = *const fn (notification: *const CapturedNotification, ctx: *anyopaque) void;

/// Filter for which notifications to capture.
pub const NotificationFilter = struct {
    /// If non-empty, only capture from these packages.
    allowed_packages: [32][256]u8 = std.mem.zeroes([32][256]u8),
    allowed_count: u8 = 0,
    /// If true, skip ongoing (persistent) notifications.
    skip_ongoing: bool = true,
    /// Minimum priority to capture.
    min_priority: CapturedNotification.Priority = .min,

    /// Add a package to the allowed list.
    pub fn addAllowedPackage(self: *NotificationFilter, pkg: []const u8) bool {
        if (self.allowed_count >= 32) return false;
        if (pkg.len > 255) return false;
        @memcpy(self.allowed_packages[self.allowed_count][0..pkg.len], pkg);
        self.allowed_count += 1;
        return true;
    }

    /// Check if a notification passes the filter.
    pub fn passes(self: *const NotificationFilter, notif: *const CapturedNotification) bool {
        if (self.skip_ongoing and notif.is_ongoing) return false;
        if (@intFromEnum(notif.priority) < @intFromEnum(self.min_priority)) return false;
        if (self.allowed_count > 0) {
            const pkg = notif.getPackageName();
            for (self.allowed_packages[0..self.allowed_count]) |entry| {
                const entry_slice = sliceToNull(&entry);
                if (std.mem.eql(u8, entry_slice, pkg)) return true;
            }
            return false;
        }
        return true;
    }
};

/// Notification listener service state.
pub const ListenerState = enum {
    disabled,
    enabled,
    connected,
    disconnected,
};

/// Notification listener controller.
pub const NotificationListener = struct {
    state: ListenerState,
    callback: NotificationCallback,
    filter: NotificationFilter,
    context: *anyopaque,
    /// Count of notifications captured since start.
    capture_count: u64,

    pub fn init(callback: NotificationCallback, context: *anyopaque) NotificationListener {
        return .{
            .state = .disabled,
            .callback = callback,
            .filter = .{},
            .context = context,
            .capture_count = 0,
        };
    }

    /// Process an incoming notification.
    pub fn onNotificationPosted(self: *NotificationListener, notif: *const CapturedNotification) void {
        if (self.state != .connected) return;
        if (!self.filter.passes(notif)) return;
        self.callback(notif, self.context);
        self.capture_count += 1;
    }

    pub fn setConnected(self: *NotificationListener) void {
        self.state = .connected;
    }

    pub fn setDisconnected(self: *NotificationListener) void {
        self.state = .disconnected;
    }
};

fn sliceToNull(buf: []const u8) []const u8 {
    var len: usize = 0;
    while (len < buf.len and buf[len] != 0) : (len += 1) {}
    return buf[0..len];
}
