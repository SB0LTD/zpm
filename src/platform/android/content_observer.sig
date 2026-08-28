// ContentObserver abstraction for Android content providers
// Layer 1: Platform (Android)
//
// Wraps Android's ContentObserver and ContentResolver for observing
// changes to SMS inbox, call log, and other content providers.
// Supports both observation (change callbacks) and bulk query.

const std = @import("std");

/// Content URI identifiers for observable providers.
pub const ContentUri = enum {
    sms_inbox,
    sms_sent,
    sms_all,
    call_log,
    contacts,
    media_images,
    media_video,

    pub fn uriString(self: ContentUri) []const u8 {
        return switch (self) {
            .sms_inbox => "content://sms/inbox",
            .sms_sent => "content://sms/sent",
            .sms_all => "content://sms",
            .call_log => "content://call_log/calls",
            .contacts => "content://contacts",
            .media_images => "content://media/external/images/media",
            .media_video => "content://media/external/video/media",
        };
    }
};

/// Type of change observed.
pub const ChangeType = enum {
    insert,
    update,
    delete,
    unknown,
};

/// Notification payload from content observer.
pub const ChangeNotification = struct {
    uri: ContentUri,
    change_type: ChangeType,
    /// Row ID if available (0 if unknown).
    row_id: u64,
    /// Timestamp of the notification in milliseconds.
    timestamp_ms: u64,
};

/// SMS record as queried from content provider.
pub const SmsRecord = struct {
    id: u64,
    address: [32]u8,
    address_len: u8,
    body: [10240]u8,
    body_len: u16,
    date_ms: u64,
    /// 1 = received, 2 = sent
    type_: u8,
    read: bool,
    thread_id: u64,
};

/// Call log record as queried from content provider.
pub const CallRecord = struct {
    id: u64,
    number: [16]u8,
    number_len: u8,
    date_ms: u64,
    duration_secs: u32,
    /// 1 = incoming, 2 = outgoing, 3 = missed, 5 = rejected
    call_type: u8,
    is_read: bool,
};

/// Callback signature for change notifications.
pub const OnChangeCallback = *const fn (notification: *const ChangeNotification, ctx: *anyopaque) void;

/// Observer registration for a content URI.
pub const ObserverRegistration = struct {
    uri: ContentUri,
    callback: OnChangeCallback,
    context: *anyopaque,
    active: bool,
};

/// Maximum number of simultaneous content observers.
pub const MAX_OBSERVERS = 16;

/// Content observer manager — registers and dispatches change notifications.
pub const ContentObserverManager = struct {
    registrations: [MAX_OBSERVERS]?ObserverRegistration,
    count: u8,

    pub fn init() ContentObserverManager {
        return .{
            .registrations = [_]?ObserverRegistration{null} ** MAX_OBSERVERS,
            .count = 0,
        };
    }

    /// Register an observer for a content URI.
    pub fn register(self: *ContentObserverManager, uri: ContentUri, callback: OnChangeCallback, context: *anyopaque) ?u8 {
        if (self.count >= MAX_OBSERVERS) return null;
        const slot = self.count;
        self.registrations[slot] = .{
            .uri = uri,
            .callback = callback,
            .context = context,
            .active = true,
        };
        self.count += 1;
        return slot;
    }

    /// Unregister an observer by slot index.
    pub fn unregister(self: *ContentObserverManager, slot: u8) void {
        if (slot < MAX_OBSERVERS) {
            if (self.registrations[slot]) |*reg| {
                reg.active = false;
            }
        }
    }

    /// Dispatch a change notification to all matching observers.
    pub fn dispatch(self: *const ContentObserverManager, notification: *const ChangeNotification) void {
        for (self.registrations) |maybe_reg| {
            if (maybe_reg) |reg| {
                if (reg.active and reg.uri == notification.uri) {
                    reg.callback(notification, reg.context);
                }
            }
        }
    }
};

/// Query parameters for bulk content reads.
pub const QueryParams = struct {
    uri: ContentUri,
    /// Maximum number of rows to return (0 = no limit).
    limit: u32 = 0,
    /// Offset for pagination.
    offset: u32 = 0,
    /// Minimum timestamp filter (0 = no filter).
    since_ms: u64 = 0,
    /// Sort order: true = newest first.
    descending: bool = true,
};
