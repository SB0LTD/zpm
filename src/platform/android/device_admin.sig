// Device administrator APIs for Android
// Layer 1: Platform (Android)
//
// Wraps Android's DevicePolicyManager for lock screen activation,
// factory reset initiation, and device admin privilege management.

const std = @import("std");

/// Device admin capabilities.
pub const AdminCapability = enum {
    lock_device,
    wipe_data,
    reset_password,
    force_lock,
    disable_camera,
    watch_login,
};

/// Device admin state.
pub const AdminState = enum {
    not_admin,
    admin_active,
    admin_disabled,
};

/// Result of a device admin operation.
pub const AdminResult = enum {
    success,
    not_admin,
    permission_denied,
    operation_failed,
    requires_confirmation,
};

/// Lock screen options.
pub const LockOptions = struct {
    /// If non-zero, set a timeout before auto-locking again after unlock.
    lock_timeout_ms: u32 = 0,
};

/// Wipe options.
pub const WipeOptions = struct {
    /// Wipe external storage as well.
    wipe_external_storage: bool = true,
    /// Reset protection data (factory reset protection).
    wipe_reset_protection: bool = false,
    /// Human-readable reason for the wipe.
    reason: [256]u8 = std.mem.zeroes([256]u8),
    reason_len: u8 = 0,
};

/// Device admin controller.
pub const DeviceAdminController = struct {
    state: AdminState,
    /// Available capabilities based on admin level.
    capabilities: [6]bool,

    pub fn init() DeviceAdminController {
        return .{
            .state = .not_admin,
            .capabilities = [_]bool{false} ** 6,
        };
    }

    /// Check if device admin is active.
    pub fn isAdmin(self: *const DeviceAdminController) bool {
        return self.state == .admin_active;
    }

    /// Check if a specific capability is available.
    pub fn hasCapability(self: *const DeviceAdminController, cap: AdminCapability) bool {
        return self.capabilities[@intFromEnum(cap)];
    }

    /// Update state from system query.
    pub fn updateState(self: *DeviceAdminController, active: bool) void {
        self.state = if (active) .admin_active else .not_admin;
    }

    /// Set capability availability.
    pub fn setCapability(self: *DeviceAdminController, cap: AdminCapability, available: bool) void {
        self.capabilities[@intFromEnum(cap)] = available;
    }

    /// Lock the device screen immediately.
    pub fn lockScreen(self: *const DeviceAdminController, _: LockOptions) AdminResult {
        if (!self.isAdmin()) return .not_admin;
        if (!self.hasCapability(.lock_device)) return .permission_denied;
        // Platform call would go here
        return .success;
    }

    /// Initiate factory reset (data wipe).
    pub fn wipeData(self: *const DeviceAdminController, _: WipeOptions) AdminResult {
        if (!self.isAdmin()) return .not_admin;
        if (!self.hasCapability(.wipe_data)) return .permission_denied;
        // This requires confirmation in the caller before execution
        return .requires_confirmation;
    }

    /// Execute confirmed wipe (after confirmation timeout/approval).
    pub fn executeWipe(self: *const DeviceAdminController, _: WipeOptions) AdminResult {
        if (!self.isAdmin()) return .not_admin;
        if (!self.hasCapability(.wipe_data)) return .permission_denied;
        // Platform call would go here — initiates factory reset
        return .success;
    }
};
