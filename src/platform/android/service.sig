// Persistent background service lifecycle for Android
// Layer 1: Platform (Android)
//
// Abstracts Android's background service lifecycle: foreground service with
// hidden notification channel, BOOT_COMPLETED receiver, WorkManager fallback
// for restart within 60 seconds of OS kill.

const std = @import("std");

/// Service state machine.
pub const ServiceState = enum {
    stopped,
    starting,
    running,
    restarting,
    destroyed,
};

/// Notification channel configuration for foreground service.
pub const NotificationChannel = struct {
    id: []const u8,
    name: []const u8,
    importance: Importance,
    show_badge: bool = false,
    /// If true, notification is hidden from status bar and recents.
    silent: bool = true,

    pub const Importance = enum {
        none,
        min,
        low,
        default_,
        high,
    };
};

/// Configuration for the background service.
pub const ServiceConfig = struct {
    /// Class name for the service component.
    service_class: []const u8,
    /// Whether to register for BOOT_COMPLETED broadcast.
    register_boot_receiver: bool = true,
    /// Whether to use WorkManager as restart fallback.
    use_work_manager_fallback: bool = true,
    /// Maximum restart delay in milliseconds.
    max_restart_delay_ms: u32 = 60_000,
    /// Notification channel for foreground service.
    notification_channel: NotificationChannel = .{
        .id = "bg_service",
        .name = "Background Service",
        .importance = .min,
        .silent = true,
    },
};

/// Callbacks the host application must implement.
pub const ServiceCallbacks = struct {
    /// Called when service is created and ready.
    on_create: *const fn (ctx: *anyopaque) void,
    /// Called when service is about to be destroyed.
    on_destroy: *const fn (ctx: *anyopaque) void,
    /// Called on each WorkManager periodic check.
    on_health_check: *const fn (ctx: *anyopaque) bool,
    /// Opaque context pointer passed to all callbacks.
    context: *anyopaque,
};

/// Background service controller.
pub const BackgroundService = struct {
    state: ServiceState,
    config: ServiceConfig,
    callbacks: ServiceCallbacks,
    restart_count: u32,
    last_alive_timestamp: u64,

    /// Initialize a new background service controller.
    pub fn init(config: ServiceConfig, callbacks: ServiceCallbacks) BackgroundService {
        return .{
            .state = .stopped,
            .config = config,
            .callbacks = callbacks,
            .restart_count = 0,
            .last_alive_timestamp = 0,
        };
    }

    /// Start the foreground service with hidden notification.
    pub fn start(self: *BackgroundService) void {
        self.state = .starting;
        self.callbacks.on_create(self.callbacks.context);
        self.state = .running;
    }

    /// Stop the service gracefully.
    pub fn stop(self: *BackgroundService) void {
        self.callbacks.on_destroy(self.callbacks.context);
        self.state = .stopped;
    }

    /// Called by the system when service is killed — schedules restart.
    pub fn onTaskRemoved(self: *BackgroundService) void {
        self.state = .restarting;
        self.restart_count += 1;
    }

    /// Check if service should restart (called from WorkManager).
    pub fn shouldRestart(self: *const BackgroundService) bool {
        return self.state == .restarting or self.state == .destroyed;
    }

    /// Update heartbeat timestamp (called periodically from service).
    pub fn heartbeat(self: *BackgroundService, timestamp_ms: u64) void {
        self.last_alive_timestamp = timestamp_ms;
    }

    /// Check if service appears dead (no heartbeat within restart delay).
    pub fn isUnresponsive(self: *const BackgroundService, current_time_ms: u64) bool {
        if (self.last_alive_timestamp == 0) return false;
        return (current_time_ms - self.last_alive_timestamp) > self.config.max_restart_delay_ms;
    }
};

/// Boot receiver state — tracks whether boot event was received.
pub const BootReceiver = struct {
    boot_received: bool = false,
    boot_timestamp: u64 = 0,

    pub fn onBootCompleted(self: *BootReceiver, timestamp_ms: u64) void {
        self.boot_received = true;
        self.boot_timestamp = timestamp_ms;
    }
};
