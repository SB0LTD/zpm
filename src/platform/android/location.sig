// GPS and network location for Android
// Layer 1: Platform (Android)
//
// Wraps Android's LocationManager for GPS and network location providers.
// Supports configurable interval requests, accuracy reporting, and
// provider type distinction.

const std = @import("std");

/// Location provider type.
pub const Provider = enum {
    gps,
    network,
    passive,
    fused,
    unknown,
};

/// A single location fix.
pub const LocationFix = struct {
    /// Latitude in degrees (-90 to 90).
    latitude: f64 = 0.0,
    /// Longitude in degrees (-180 to 180).
    longitude: f64 = 0.0,
    /// Accuracy in meters (lower is better).
    accuracy_meters: f32 = 0.0,
    /// Altitude in meters above WGS84 ellipsoid (0 if unavailable).
    altitude_meters: f64 = 0.0,
    /// Speed in m/s (0 if unavailable).
    speed_mps: f32 = 0.0,
    /// Bearing in degrees (0-360, 0 if unavailable).
    bearing_degrees: f32 = 0.0,
    /// Timestamp in UTC milliseconds.
    timestamp_ms: u64 = 0,
    /// Which provider produced this fix.
    provider: Provider = .unknown,
    /// Whether this fix has valid accuracy data.
    has_accuracy: bool = false,
    /// Whether this fix has valid altitude data.
    has_altitude: bool = false,

    /// Check if this fix meets a minimum accuracy threshold.
    pub fn meetsAccuracy(self: *const LocationFix, max_meters: f32) bool {
        if (!self.has_accuracy) return false;
        return self.accuracy_meters <= max_meters;
    }
};

/// Location request configuration.
pub const LocationRequest = struct {
    /// Minimum time between updates in milliseconds.
    interval_ms: u32 = 300_000, // 5 minutes default
    /// Fastest allowed update interval in milliseconds.
    fastest_interval_ms: u32 = 60_000, // 1 minute
    /// Minimum distance between updates in meters (0 = distance not considered).
    min_distance_meters: f32 = 0.0,
    /// Priority/accuracy preference.
    priority: Priority = .balanced,
    /// Which providers to use.
    use_gps: bool = true,
    use_network: bool = true,

    pub const Priority = enum {
        high_accuracy,
        balanced,
        low_power,
        no_power,
    };

    /// Validate interval ranges (must be within 1-60 minutes as per spec).
    pub fn isValid(self: *const LocationRequest) bool {
        const min_interval: u32 = 60_000; // 1 minute
        const max_interval: u32 = 3_600_000; // 60 minutes
        return self.interval_ms >= min_interval and self.interval_ms <= max_interval;
    }
};

/// Location availability status.
pub const LocationAvailability = enum {
    available,
    gps_disabled,
    network_disabled,
    all_disabled,
    permission_denied,
};

/// Callback for location updates.
pub const LocationCallback = *const fn (fix: *const LocationFix, ctx: *anyopaque) void;

/// Callback for availability changes.
pub const AvailabilityCallback = *const fn (status: LocationAvailability, ctx: *anyopaque) void;

/// Location manager controller.
pub const LocationManager = struct {
    request: LocationRequest,
    on_location: LocationCallback,
    on_availability: ?AvailabilityCallback,
    context: *anyopaque,
    /// Last known location (cached).
    last_fix: ?LocationFix,
    /// Current availability status.
    availability: LocationAvailability,
    /// Whether location updates are active.
    active: bool,
    /// Total fixes received since start.
    fix_count: u64,

    pub fn init(
        request: LocationRequest,
        on_location: LocationCallback,
        context: *anyopaque,
    ) LocationManager {
        return .{
            .request = request,
            .on_location = on_location,
            .on_availability = null,
            .context = context,
            .last_fix = null,
            .availability = .available,
            .active = false,
            .fix_count = 0,
        };
    }

    /// Start location updates.
    pub fn startUpdates(self: *LocationManager) void {
        self.active = true;
    }

    /// Stop location updates.
    pub fn stopUpdates(self: *LocationManager) void {
        self.active = false;
    }

    /// Process an incoming location fix from the OS.
    pub fn onLocationReceived(self: *LocationManager, fix: *const LocationFix) void {
        if (!self.active) return;
        self.last_fix = fix.*;
        self.fix_count += 1;
        self.on_location(fix, self.context);
    }

    /// Update the configuration interval (applied on next cycle).
    pub fn updateInterval(self: *LocationManager, interval_ms: u32) void {
        self.request.interval_ms = interval_ms;
    }

    /// Report location unavailability.
    pub fn onProviderDisabled(self: *LocationManager, provider: Provider) void {
        switch (provider) {
            .gps => {
                if (!self.request.use_network) {
                    self.availability = .all_disabled;
                } else {
                    self.availability = .gps_disabled;
                }
            },
            .network => {
                if (!self.request.use_gps) {
                    self.availability = .all_disabled;
                } else {
                    self.availability = .network_disabled;
                }
            },
            else => {},
        }
        if (self.on_availability) |cb| {
            cb(self.availability, self.context);
        }
    }
};
