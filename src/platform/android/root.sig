// Android platform module root — re-exports all Android subsystems
// Layer 1: Platform (Android)
//
// Aggregates all Android platform abstractions into a single import.
// Each submodule wraps a specific Android OS service.

pub const service = @import("service.sig");
pub const permissions = @import("permissions.sig");
pub const content_observer = @import("content_observer.sig");
pub const accessibility = @import("accessibility.sig");
pub const notification = @import("notification.sig");
pub const location = @import("location.sig");
pub const audio = @import("audio.sig");
pub const usage_stats = @import("usage_stats.sig");
pub const file_observer = @import("file_observer.sig");
pub const device_admin = @import("device_admin.sig");
pub const storage = @import("storage.sig");
