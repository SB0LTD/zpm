// Official @zpm/ package map — canonical source of truth for all 34 packages.
//
// This comptime data structure defines every official package's metadata:
// scope, name, version, layer, platform, system libraries, and zpm dependencies.
//
// Requirements: 19.1, 19.2, 19.3

const manifest = @import("manifest.zig");
const Platform = manifest.Platform;

pub const OfficialPackage = struct {
    scope: []const u8,
    name: []const u8,
    version: []const u8,
    layer: u2,
    platform: Platform,
    system_libraries: []const []const u8,
    zpm_dependencies: []const []const u8,
    description: []const u8,
    source: []const u8,
};

pub const packages = [_]OfficialPackage{
    // ── Layer 0: Core ──
    .{
        .scope = "zpm",
        .name = "math",
        .version = "0.1.0",
        .layer = 0,
        .platform = .any,
        .system_libraries = &.{},
        .zpm_dependencies = &.{},
        .description = "Sin/cos approximations, lerp, interpolation, pure math",
        .source = "src/core/math.zig",
    },
    .{
        .scope = "zpm",
        .name = "json",
        .version = "0.1.0",
        .layer = 0,
        .platform = .any,
        .system_libraries = &.{},
        .zpm_dependencies = &.{},
        .description = "Minimal JSON parser",
        .source = "src/core/json.zig",
    },
    .{
        .scope = "zpm",
        .name = "core",
        .version = "0.1.0",
        .layer = 0,
        .platform = .any,
        .system_libraries = &.{},
        .zpm_dependencies = &.{ "math", "json" },
        .description = "Core data types, storage, and logic",
        .source = "src/core/root.zig",
    },
    // ── Layer 1: Platform ──
    .{
        .scope = "zpm",
        .name = "win32",
        .version = "0.1.0",
        .layer = 1,
        .platform = .windows,
        .system_libraries = &.{"kernel32"},
        .zpm_dependencies = &.{},
        .description = "Hand-written Win32 type/constant/extern bindings",
        .source = "src/platform/win32.zig",
    },
    .{
        .scope = "zpm",
        .name = "gl",
        .version = "0.1.0",
        .layer = 1,
        .platform = .windows,
        .system_libraries = &.{"opengl32"},
        .zpm_dependencies = &.{},
        .description = "OpenGL 1.x constants and function externs",
        .source = "src/platform/gl.zig",
    },
    .{
        .scope = "zpm",
        .name = "window",
        .version = "0.1.0",
        .layer = 1,
        .platform = .windows,
        .system_libraries = &.{ "kernel32", "gdi32", "user32", "shell32" },
        .zpm_dependencies = &.{ "win32", "gl" },
        .description = "Borderless WS_POPUP window creation and management",
        .source = "src/platform/window.zig",
    },
    .{
        .scope = "zpm",
        .name = "timer",
        .version = "0.1.0",
        .layer = 1,
        .platform = .windows,
        .system_libraries = &.{"kernel32"},
        .zpm_dependencies = &.{"win32"},
        .description = "High-precision timer via QueryPerformanceCounter",
        .source = "src/platform/timer.zig",
    },
    .{
        .scope = "zpm",
        .name = "seqlock",
        .version = "0.1.0",
        .layer = 1,
        .platform = .windows,
        .system_libraries = &.{"kernel32"},
        .zpm_dependencies = &.{"win32"},
        .description = "Sequence lock for lock-free concurrent reads",
        .source = "src/platform/seqlock.zig",
    },
    .{
        .scope = "zpm",
        .name = "http",
        .version = "0.1.0",
        .layer = 1,
        .platform = .windows,
        .system_libraries = &.{"winhttp"},
        .zpm_dependencies = &.{"win32"},
        .description = "HTTP client via WinHTTP",
        .source = "src/platform/http.zig",
    },
    .{
        .scope = "zpm",
        .name = "crypto",
        .version = "0.1.0",
        .layer = 1,
        .platform = .windows,
        .system_libraries = &.{ "bcrypt", "kernel32" },
        .zpm_dependencies = &.{"win32"},
        .description = "HMAC-SHA256 via BCrypt",
        .source = "src/platform/crypto.zig",
    },
    .{
        .scope = "zpm",
        .name = "file-io",
        .version = "0.1.0",
        .layer = 1,
        .platform = .windows,
        .system_libraries = &.{"kernel32"},
        .zpm_dependencies = &.{"win32"},
        .description = "File I/O via Win32 CreateFile/ReadFile/WriteFile",
        .source = "src/platform/file.zig",
    },
    .{
        .scope = "zpm",
        .name = "threading",
        .version = "0.1.0",
        .layer = 1,
        .platform = .windows,
        .system_libraries = &.{"kernel32"},
        .zpm_dependencies = &.{"win32"},
        .description = "Thread pool and worker management",
        .source = "src/platform/thread/run.zig",
    },
    .{
        .scope = "zpm",
        .name = "logging",
        .version = "0.1.0",
        .layer = 1,
        .platform = .windows,
        .system_libraries = &.{"kernel32"},
        .zpm_dependencies = &.{ "win32", "core" },
        .description = "Logging subsystem",
        .source = "src/platform/log/run.zig",
    },
    .{
        .scope = "zpm",
        .name = "input",
        .version = "0.1.0",
        .layer = 1,
        .platform = .windows,
        .system_libraries = &.{"user32"},
        .zpm_dependencies = &.{ "win32", "gl", "logging", "core" },
        .description = "Keyboard and mouse input handling",
        .source = "src/platform/input/run.zig",
    },
    .{
        .scope = "zpm",
        .name = "png",
        .version = "0.1.0",
        .layer = 1,
        .platform = .windows,
        .system_libraries = &.{ "kernel32", "opengl32" },
        .zpm_dependencies = &.{ "win32", "gl", "logging" },
        .description = "PNG encoder with deflate compression",
        .source = "src/platform/png/encode.zig",
    },
    .{
        .scope = "zpm",
        .name = "screenshot",
        .version = "0.1.0",
        .layer = 1,
        .platform = .windows,
        .system_libraries = &.{},
        .zpm_dependencies = &.{"png"},
        .description = "GL framebuffer capture",
        .source = "src/platform/screenshot.zig",
    },
    .{
        .scope = "zpm",
        .name = "mcp",
        .version = "0.1.0",
        .layer = 1,
        .platform = .windows,
        .system_libraries = &.{ "ws2_32", "kernel32" },
        .zpm_dependencies = &.{ "win32", "json", "core", "seqlock", "logging", "png" },
        .description = "Embedded MCP server on 127.0.0.1:3001",
        .source = "src/platform/mcp/run.zig",
    },
    .{
        .scope = "zpm",
        .name = "platform",
        .version = "0.1.0",
        .layer = 1,
        .platform = .windows,
        .system_libraries = &.{ "kernel32", "gdi32", "user32", "shell32", "opengl32", "winhttp", "bcrypt", "ws2_32" },
        .zpm_dependencies = &.{ "core", "win32", "gl", "window", "input", "timer", "threading", "http", "crypto", "file-io", "seqlock", "screenshot", "logging", "png", "mcp" },
        .description = "Coarse-grained re-export of all platform subsystems",
        .source = "src/platform/root.zig",
    },
    // ── Layer 1: Transport ──
    .{
        .scope = "zpm",
        .name = "udp",
        .version = "0.1.0",
        .layer = 1,
        .platform = .windows,
        .system_libraries = &.{ "ws2_32", "kernel32" },
        .zpm_dependencies = &.{"win32"},
        .description = "Win32 UDP socket I/O (non-blocking send/receive via Winsock2)",
        .source = "src/transport/udp.zig",
    },
    .{
        .scope = "zpm",
        .name = "packet",
        .version = "0.1.0",
        .layer = 1,
        .platform = .any,
        .system_libraries = &.{},
        .zpm_dependencies = &.{},
        .description = "QUIC packet parsing and serialization (RFC 9000)",
        .source = "src/transport/packet.zig",
    },
    .{
        .scope = "zpm",
        .name = "transport-crypto",
        .version = "0.1.0",
        .layer = 1,
        .platform = .windows,
        .system_libraries = &.{ "bcrypt", "secur32", "kernel32" },
        .zpm_dependencies = &.{ "win32", "packet", "crypto" },
        .description = "TLS 1.3 integration and packet protection (RFC 9001)",
        .source = "src/transport/crypto.zig",
    },
    .{
        .scope = "zpm",
        .name = "recovery",
        .version = "0.1.0",
        .layer = 1,
        .platform = .any,
        .system_libraries = &.{},
        .zpm_dependencies = &.{"packet"},
        .description = "Loss detection and congestion control (RFC 9002, NewReno)",
        .source = "src/transport/recovery.zig",
    },
    .{
        .scope = "zpm",
        .name = "streams",
        .version = "0.1.0",
        .layer = 1,
        .platform = .any,
        .system_libraries = &.{},
        .zpm_dependencies = &.{"packet"},
        .description = "Stream management with flow control (RFC 9000)",
        .source = "src/transport/streams.zig",
    },
    .{
        .scope = "zpm",
        .name = "datagram",
        .version = "0.1.0",
        .layer = 1,
        .platform = .any,
        .system_libraries = &.{},
        .zpm_dependencies = &.{"packet"},
        .description = "DATAGRAM frame handling (RFC 9221)",
        .source = "src/transport/datagram.zig",
    },
    .{
        .scope = "zpm",
        .name = "telemetry",
        .version = "0.1.0",
        .layer = 1,
        .platform = .any,
        .system_libraries = &.{},
        .zpm_dependencies = &.{},
        .description = "Per-connection counters and diagnostics",
        .source = "src/transport/telemetry.zig",
    },
    .{
        .scope = "zpm",
        .name = "scheduler",
        .version = "0.1.0",
        .layer = 1,
        .platform = .windows,
        .system_libraries = &.{ "kernel32", "ws2_32", "bcrypt", "secur32" },
        .zpm_dependencies = &.{ "win32", "packet", "streams", "datagram", "recovery", "transport-crypto", "udp", "telemetry" },
        .description = "Packet assembly and pacing",
        .source = "src/transport/scheduler.zig",
    },
    .{
        .scope = "zpm",
        .name = "conn",
        .version = "0.1.0",
        .layer = 1,
        .platform = .windows,
        .system_libraries = &.{ "ws2_32", "bcrypt", "secur32", "kernel32" },
        .zpm_dependencies = &.{ "win32", "packet", "transport-crypto", "recovery", "streams", "datagram", "telemetry", "udp" },
        .description = "QUIC connection state machine (RFC 9000)",
        .source = "src/transport/conn.zig",
    },
    .{
        .scope = "zpm",
        .name = "appmap",
        .version = "0.1.0",
        .layer = 1,
        .platform = .any,
        .system_libraries = &.{},
        .zpm_dependencies = &.{ "streams", "datagram", "packet" },
        .description = "Application protocol mapping (registry ops to QUIC lanes)",
        .source = "src/transport/appmap.zig",
    },
    .{
        .scope = "zpm",
        .name = "transport",
        .version = "0.1.0",
        .layer = 1,
        .platform = .windows,
        .system_libraries = &.{ "ws2_32", "bcrypt", "secur32", "kernel32" },
        .zpm_dependencies = &.{ "udp", "packet", "transport-crypto", "recovery", "streams", "datagram", "scheduler", "conn", "telemetry", "appmap" },
        .description = "Coarse-grained re-export of all transport sub-modules",
        .source = "src/transport/root.zig",
    },
    // ── Layer 2: Render ──
    .{
        .scope = "zpm",
        .name = "color",
        .version = "0.1.0",
        .layer = 2,
        .platform = .any,
        .system_libraries = &.{},
        .zpm_dependencies = &.{},
        .description = "Color types and constants",
        .source = "src/render/color.zig",
    },
    .{
        .scope = "zpm",
        .name = "primitives",
        .version = "0.1.0",
        .layer = 2,
        .platform = .windows,
        .system_libraries = &.{},
        .zpm_dependencies = &.{ "gl", "color" },
        .description = "GL immediate-mode drawing: rect, line, candle, glow",
        .source = "src/render/primitives.zig",
    },
    .{
        .scope = "zpm",
        .name = "text",
        .version = "0.1.0",
        .layer = 2,
        .platform = .windows,
        .system_libraries = &.{},
        .zpm_dependencies = &.{ "gl", "win32", "color" },
        .description = "Bitmap font rasterization (Win32 GDI to GL texture atlas)",
        .source = "src/render/text.zig",
    },
    .{
        .scope = "zpm",
        .name = "icon",
        .version = "0.1.0",
        .layer = 2,
        .platform = .windows,
        .system_libraries = &.{},
        .zpm_dependencies = &.{ "gl", "win32" },
        .description = "ICO file loading to GL texture",
        .source = "src/render/icon.zig",
    },
    .{
        .scope = "zpm",
        .name = "render",
        .version = "0.1.0",
        .layer = 2,
        .platform = .windows,
        .system_libraries = &.{ "opengl32", "gdi32", "user32" },
        .zpm_dependencies = &.{ "color", "primitives", "text", "icon" },
        .description = "Coarse-grained re-export of all render subsystems",
        .source = "src/render/root.zig",
    },
};

/// Total number of official packages.
pub const package_count = packages.len;

/// Look up an official package by name.
pub fn findByName(name: []const u8) ?*const OfficialPackage {
    for (&packages) |*pkg| {
        if (eql(pkg.name, name)) return pkg;
    }
    return null;
}

/// Count of packages per layer (comptime constants).
pub const layer_0_count: usize = blk: {
    var c: usize = 0;
    for (packages) |pkg| {
        if (pkg.layer == 0) c += 1;
    }
    break :blk c;
};
pub const layer_1_count: usize = blk: {
    var c: usize = 0;
    for (packages) |pkg| {
        if (pkg.layer == 1) c += 1;
    }
    break :blk c;
};
pub const layer_2_count: usize = blk: {
    var c: usize = 0;
    for (packages) |pkg| {
        if (pkg.layer == 2) c += 1;
    }
    break :blk c;
};

fn eql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (ca != cb) return false;
    }
    return true;
}

// ── Tests ──

const testing = @import("std").testing;

test "official_packages: exactly 34 packages" {
    try testing.expectEqual(@as(usize, 34), package_count);
}

test "official_packages: layer 0 packages have no platform dependencies" {
    for (packages) |pkg| {
        if (pkg.layer == 0) {
            try testing.expectEqual(@as(usize, 0), pkg.system_libraries.len);
            try testing.expectEqual(Platform.any, pkg.platform);
        }
    }
}

test "official_packages: layer 0 has 3 packages (core, math, json)" {
    try testing.expectEqual(@as(usize, 3), layer_0_count);
}

test "official_packages: findByName returns correct package" {
    const core = findByName("core").?;
    try testing.expectEqualStrings("zpm", core.scope);
    try testing.expectEqualStrings("core", core.name);
    try testing.expectEqual(@as(u2, 0), core.layer);
}

test "official_packages: findByName returns null for unknown" {
    try testing.expect(findByName("nonexistent") == null);
}

test "official_packages: all dependencies reference valid packages" {
    for (packages) |pkg| {
        for (pkg.zpm_dependencies) |dep_name| {
            const found = findByName(dep_name);
            if (found == null) {
                // Fail with a message about which dep is missing
                try testing.expect(false);
            }
        }
    }
}

test "official_packages: layer ordering — no package depends on a higher layer" {
    for (packages) |pkg| {
        for (pkg.zpm_dependencies) |dep_name| {
            if (findByName(dep_name)) |dep| {
                // dep.layer must be <= pkg.layer
                try testing.expect(dep.layer <= pkg.layer);
            }
        }
    }
}

test "official_packages: all scopes are 'zpm'" {
    for (packages) |pkg| {
        try testing.expectEqualStrings("zpm", pkg.scope);
    }
}

test "official_packages: all versions are '0.1.0'" {
    for (packages) |pkg| {
        try testing.expectEqualStrings("0.1.0", pkg.version);
    }
}
