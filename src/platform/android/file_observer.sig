// File system monitoring for Android media directories
// Layer 1: Platform (Android)
//
// Wraps Android's FileObserver for detecting new media files (photos, videos)
// in user-accessible storage directories.

const std = @import("std");

/// Supported media file formats.
pub const MediaFormat = enum {
    jpeg,
    png,
    gif,
    mp4,
    three_gp,
    unknown,

    /// Detect format from file extension.
    pub fn fromExtension(ext: []const u8) MediaFormat {
        if (eqlIgnoreCase(ext, "jpg") or eqlIgnoreCase(ext, "jpeg")) return .jpeg;
        if (eqlIgnoreCase(ext, "png")) return .png;
        if (eqlIgnoreCase(ext, "gif")) return .gif;
        if (eqlIgnoreCase(ext, "mp4")) return .mp4;
        if (eqlIgnoreCase(ext, "3gp")) return .three_gp;
        return .unknown;
    }

    /// Whether this format is one we track.
    pub fn isSupported(self: MediaFormat) bool {
        return self != .unknown;
    }

    /// Whether this is a video format.
    pub fn isVideo(self: MediaFormat) bool {
        return self == .mp4 or self == .three_gp;
    }
};

/// File event type from FileObserver.
pub const FileEvent = enum {
    created,
    modified,
    deleted,
    moved_from,
    moved_to,
    close_write,
};

/// Detected media file metadata.
pub const DetectedFile = struct {
    /// Full file path.
    path: [1024]u8 = std.mem.zeroes([1024]u8),
    path_len: u16 = 0,
    /// Filename only.
    filename: [256]u8 = std.mem.zeroes([256]u8),
    filename_len: u8 = 0,
    /// File size in bytes.
    size_bytes: u64 = 0,
    /// Creation/modification timestamp in UTC milliseconds.
    timestamp_ms: u64 = 0,
    /// Detected media format.
    format: MediaFormat = .unknown,
    /// Event that triggered detection.
    event: FileEvent = .created,

    pub fn getPath(self: *const DetectedFile) []const u8 {
        return self.path[0..self.path_len];
    }

    pub fn getFilename(self: *const DetectedFile) []const u8 {
        return self.filename[0..self.filename_len];
    }

    /// Check if file exceeds maximum size for auto-upload (500 MB).
    pub fn exceedsMaxAutoUpload(self: *const DetectedFile) bool {
        return self.size_bytes > 500 * 1024 * 1024;
    }
};

/// Callback for detected media files.
pub const FileDetectedCallback = *const fn (file: *const DetectedFile, ctx: *anyopaque) void;

/// Directories to monitor.
pub const MonitoredDirectory = struct {
    path: [512]u8 = std.mem.zeroes([512]u8),
    path_len: u16 = 0,
    active: bool = false,

    pub fn getPath(self: *const MonitoredDirectory) []const u8 {
        return self.path[0..self.path_len];
    }
};

/// Maximum monitored directories.
pub const MAX_MONITORED_DIRS = 16;

/// File observer controller.
pub const FileObserverController = struct {
    callback: FileDetectedCallback,
    context: *anyopaque,
    /// Directories being monitored.
    directories: [MAX_MONITORED_DIRS]MonitoredDirectory,
    dir_count: u8,
    /// Whether observation is active.
    active: bool,
    /// Total files detected since start.
    detection_count: u64,

    pub fn init(callback: FileDetectedCallback, context: *anyopaque) FileObserverController {
        return .{
            .callback = callback,
            .context = context,
            .directories = std.mem.zeroes([MAX_MONITORED_DIRS]MonitoredDirectory),
            .dir_count = 0,
            .active = false,
            .detection_count = 0,
        };
    }

    /// Add a directory to monitor.
    pub fn addDirectory(self: *FileObserverController, path: []const u8) bool {
        if (self.dir_count >= MAX_MONITORED_DIRS) return false;
        if (path.len > 511) return false;
        @memcpy(self.directories[self.dir_count].path[0..path.len], path);
        self.directories[self.dir_count].path_len = @intCast(path.len);
        self.directories[self.dir_count].active = true;
        self.dir_count += 1;
        return true;
    }

    /// Start observing all registered directories.
    pub fn startObserving(self: *FileObserverController) void {
        self.active = true;
    }

    /// Stop all observation.
    pub fn stopObserving(self: *FileObserverController) void {
        self.active = false;
    }

    /// Process a file event from the OS.
    pub fn onFileEvent(self: *FileObserverController, file: *const DetectedFile) void {
        if (!self.active) return;
        if (!file.format.isSupported()) return;
        self.detection_count += 1;
        self.callback(file, self.context);
    }
};

// ── Helpers ──

fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (toLower(ca) != toLower(cb)) return false;
    }
    return true;
}

fn toLower(c: u8) u8 {
    return if (c >= 'A' and c <= 'Z') c + 32 else c;
}
