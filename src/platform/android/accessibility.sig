// AccessibilityService abstraction for Android
// Layer 1: Platform (Android)
//
// Wraps Android AccessibilityService events for text extraction from IM
// messages, browser URLs, and window changes. Provides a callback-based
// interface for capturing accessibility node content.

const std = @import("std");

/// Type of accessibility event received.
pub const EventType = enum {
    /// A new window appeared or active window changed.
    window_state_changed,
    /// Content within a window changed (text update, scroll, etc.).
    window_content_changed,
    /// A view was clicked.
    view_clicked,
    /// A view gained focus.
    view_focused,
    /// Text was changed in an editable view.
    view_text_changed,
    /// Notification was posted.
    notification_state_changed,
    /// Text selection changed.
    view_text_selection_changed,
    /// Scroll event.
    view_scrolled,
};

/// Source app category for event routing.
pub const AppCategory = enum {
    whatsapp,
    telegram,
    browser_chrome,
    browser_firefox,
    browser_other,
    other,

    pub fn fromPackageName(pkg: []const u8) AppCategory {
        if (strContains(pkg, "com.whatsapp")) return .whatsapp;
        if (strContains(pkg, "org.telegram")) return .telegram;
        if (strContains(pkg, "com.android.chrome")) return .browser_chrome;
        if (strContains(pkg, "org.mozilla.firefox")) return .browser_firefox;
        if (strContains(pkg, "browser") or strContains(pkg, "webview")) return .browser_other;
        return .other;
    }
};

/// Extracted text content from an accessibility node.
pub const ExtractedText = struct {
    /// The text content (up to 10KB).
    text: [10240]u8 = std.mem.zeroes([10240]u8),
    text_len: u16 = 0,
    /// Package name of the source app.
    package_name: [256]u8 = std.mem.zeroes([256]u8),
    package_name_len: u8 = 0,
    /// View ID or class name hint.
    view_id: [128]u8 = std.mem.zeroes([128]u8),
    view_id_len: u8 = 0,
    /// Timestamp of extraction.
    timestamp_ms: u64 = 0,
    /// Event type that triggered extraction.
    event_type: EventType = .window_content_changed,
    /// App category for routing.
    category: AppCategory = .other,

    pub fn getText(self: *const ExtractedText) []const u8 {
        return self.text[0..self.text_len];
    }

    pub fn getPackageName(self: *const ExtractedText) []const u8 {
        return self.package_name[0..self.package_name_len];
    }
};

/// Extracted URL from a browser address bar.
pub const ExtractedUrl = struct {
    url: [2048]u8 = std.mem.zeroes([2048]u8),
    url_len: u16 = 0,
    title: [512]u8 = std.mem.zeroes([512]u8),
    title_len: u16 = 0,
    package_name: [256]u8 = std.mem.zeroes([256]u8),
    package_name_len: u8 = 0,
    timestamp_ms: u64 = 0,

    pub fn getUrl(self: *const ExtractedUrl) []const u8 {
        return self.url[0..self.url_len];
    }

    pub fn getTitle(self: *const ExtractedUrl) []const u8 {
        return self.title[0..self.title_len];
    }
};

/// Window change event data.
pub const WindowChange = struct {
    package_name: [256]u8 = std.mem.zeroes([256]u8),
    package_name_len: u8 = 0,
    window_title: [256]u8 = std.mem.zeroes([256]u8),
    window_title_len: u8 = 0,
    timestamp_ms: u64 = 0,

    pub fn getPackageName(self: *const WindowChange) []const u8 {
        return self.package_name[0..self.package_name_len];
    }
};

/// Callbacks for accessibility events.
pub const AccessibilityCallbacks = struct {
    /// Called when IM message text is extracted.
    on_message_text: ?*const fn (text: *const ExtractedText, ctx: *anyopaque) void = null,
    /// Called when browser URL is extracted.
    on_url_change: ?*const fn (url: *const ExtractedUrl, ctx: *anyopaque) void = null,
    /// Called when active window changes.
    on_window_change: ?*const fn (change: *const WindowChange, ctx: *anyopaque) void = null,
    /// Opaque context.
    context: *anyopaque,
};

/// Accessibility service state.
pub const AccessibilityState = enum {
    disabled,
    enabled,
    connected,
    disconnected,
};

/// Accessibility service controller.
pub const AccessibilityController = struct {
    state: AccessibilityState,
    callbacks: AccessibilityCallbacks,
    /// Packages to monitor (null-terminated list).
    monitored_packages: [32][256]u8,
    monitored_count: u8,

    pub fn init(callbacks: AccessibilityCallbacks) AccessibilityController {
        return .{
            .state = .disabled,
            .callbacks = callbacks,
            .monitored_packages = std.mem.zeroes([32][256]u8),
            .monitored_count = 0,
        };
    }

    /// Add a package name to the monitored list.
    pub fn addMonitoredPackage(self: *AccessibilityController, pkg: []const u8) bool {
        if (self.monitored_count >= 32) return false;
        if (pkg.len > 255) return false;
        @memcpy(self.monitored_packages[self.monitored_count][0..pkg.len], pkg);
        self.monitored_count += 1;
        return true;
    }

    /// Check if a package is being monitored.
    pub fn isMonitored(self: *const AccessibilityController, pkg: []const u8) bool {
        for (self.monitored_packages[0..self.monitored_count]) |entry| {
            const entry_slice = std.mem.sliceTo(&entry, 0);
            if (std.mem.eql(u8, entry_slice, pkg)) return true;
        }
        return false;
    }

    /// Process an incoming accessibility event.
    pub fn processEvent(self: *AccessibilityController, text: *const ExtractedText) void {
        if (self.state != .connected) return;
        const pkg = text.getPackageName();
        if (!self.isMonitored(pkg)) return;

        switch (text.category) {
            .whatsapp, .telegram => {
                if (self.callbacks.on_message_text) |cb| {
                    cb(text, self.callbacks.context);
                }
            },
            .browser_chrome, .browser_firefox, .browser_other => {
                // Browser events are handled via on_url_change with ExtractedUrl
            },
            .other => {},
        }
    }

    pub fn setConnected(self: *AccessibilityController) void {
        self.state = .connected;
    }

    pub fn setDisconnected(self: *AccessibilityController) void {
        self.state = .disconnected;
    }
};

// ── Helpers ──

fn strContains(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.mem.eql(u8, haystack[i..][0..needle.len], needle)) return true;
    }
    return false;
}
