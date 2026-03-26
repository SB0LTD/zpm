const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ── Granular modules (Layer 0: Core) ──

    const math_mod = b.addModule("math", .{
        .root_source_file = b.path("src/core/math.zig"),
        .target = target,
        .optimize = optimize,
    });

    const json_mod = b.addModule("json", .{
        .root_source_file = b.path("src/core/json.zig"),
        .target = target,
        .optimize = optimize,
    });

    const core_mod = b.addModule("core", .{
        .root_source_file = b.path("src/core/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    core_mod.addImport("math", math_mod);
    core_mod.addImport("json", json_mod);

    // ── Granular modules (Layer 1: Platform) ──
    // Ordered so that dependencies are declared before dependents.

    const win32_mod = b.addModule("win32", .{
        .root_source_file = b.path("src/platform/win32.zig"),
        .target = target,
        .optimize = optimize,
    });
    win32_mod.linkSystemLibrary("kernel32", .{});

    const gl_mod = b.addModule("gl", .{
        .root_source_file = b.path("src/platform/gl.zig"),
        .target = target,
        .optimize = optimize,
    });
    gl_mod.linkSystemLibrary("opengl32", .{});

    const window_mod = b.addModule("window", .{
        .root_source_file = b.path("src/platform/window.zig"),
        .target = target,
        .optimize = optimize,
    });
    window_mod.addImport("win32", win32_mod);
    window_mod.addImport("gl", gl_mod);
    window_mod.linkSystemLibrary("kernel32", .{});
    window_mod.linkSystemLibrary("gdi32", .{});
    window_mod.linkSystemLibrary("user32", .{});
    window_mod.linkSystemLibrary("shell32", .{});

    const timer_mod = b.addModule("timer", .{
        .root_source_file = b.path("src/platform/timer.zig"),
        .target = target,
        .optimize = optimize,
    });
    timer_mod.addImport("win32", win32_mod);
    timer_mod.linkSystemLibrary("kernel32", .{});

    const seqlock_mod = b.addModule("seqlock", .{
        .root_source_file = b.path("src/platform/seqlock.zig"),
        .target = target,
        .optimize = optimize,
    });
    seqlock_mod.addImport("win32", win32_mod);
    seqlock_mod.linkSystemLibrary("kernel32", .{});

    const http_mod = b.addModule("http", .{
        .root_source_file = b.path("src/platform/http.zig"),
        .target = target,
        .optimize = optimize,
    });
    http_mod.addImport("win32", win32_mod);
    http_mod.linkSystemLibrary("winhttp", .{});

    const crypto_mod = b.addModule("crypto", .{
        .root_source_file = b.path("src/platform/crypto.zig"),
        .target = target,
        .optimize = optimize,
    });
    crypto_mod.addImport("win32", win32_mod);
    crypto_mod.linkSystemLibrary("bcrypt", .{});
    crypto_mod.linkSystemLibrary("kernel32", .{});

    const file_io_mod = b.addModule("file_io", .{
        .root_source_file = b.path("src/platform/file.zig"),
        .target = target,
        .optimize = optimize,
    });
    file_io_mod.addImport("win32", win32_mod);
    file_io_mod.linkSystemLibrary("kernel32", .{});

    const threading_mod = b.addModule("threading", .{
        .root_source_file = b.path("src/platform/thread/run.zig"),
        .target = target,
        .optimize = optimize,
    });
    threading_mod.addImport("win32", win32_mod);
    threading_mod.linkSystemLibrary("kernel32", .{});

    const logging_mod = b.addModule("logging", .{
        .root_source_file = b.path("src/platform/log/run.zig"),
        .target = target,
        .optimize = optimize,
    });
    logging_mod.addImport("win32", win32_mod);
    logging_mod.addImport("core", core_mod);
    logging_mod.linkSystemLibrary("kernel32", .{});

    const input_mod = b.addModule("input", .{
        .root_source_file = b.path("src/platform/input/run.zig"),
        .target = target,
        .optimize = optimize,
    });
    input_mod.addImport("win32", win32_mod);
    input_mod.addImport("gl", gl_mod);
    input_mod.addImport("logging", logging_mod);
    input_mod.addImport("core", core_mod);
    input_mod.linkSystemLibrary("user32", .{});

    const png_mod = b.addModule("png", .{
        .root_source_file = b.path("src/platform/png/encode.zig"),
        .target = target,
        .optimize = optimize,
    });
    png_mod.addImport("win32", win32_mod);
    png_mod.addImport("gl", gl_mod);
    png_mod.addImport("logging", logging_mod);
    png_mod.linkSystemLibrary("kernel32", .{});
    png_mod.linkSystemLibrary("opengl32", .{});

    const screenshot_mod = b.addModule("screenshot", .{
        .root_source_file = b.path("src/platform/screenshot.zig"),
        .target = target,
        .optimize = optimize,
    });
    screenshot_mod.addImport("png", png_mod);

    const mcp_mod = b.addModule("mcp", .{
        .root_source_file = b.path("src/platform/mcp/run.zig"),
        .target = target,
        .optimize = optimize,
    });
    mcp_mod.addImport("win32", win32_mod);
    mcp_mod.addImport("json", json_mod);
    mcp_mod.addImport("core", core_mod);
    mcp_mod.addImport("seqlock", seqlock_mod);
    mcp_mod.addImport("logging", logging_mod);
    mcp_mod.addImport("png", png_mod);
    mcp_mod.linkSystemLibrary("ws2_32", .{});
    mcp_mod.linkSystemLibrary("kernel32", .{});

    // ── Granular modules (Layer 2: Render) ──

    const color_mod = b.addModule("color", .{
        .root_source_file = b.path("src/render/color.zig"),
        .target = target,
        .optimize = optimize,
    });

    const primitives_mod = b.addModule("primitives", .{
        .root_source_file = b.path("src/render/primitives.zig"),
        .target = target,
        .optimize = optimize,
    });
    primitives_mod.addImport("gl", gl_mod);
    primitives_mod.addImport("color", color_mod);

    const text_mod = b.addModule("text", .{
        .root_source_file = b.path("src/render/text.zig"),
        .target = target,
        .optimize = optimize,
    });
    text_mod.addImport("gl", gl_mod);
    text_mod.addImport("win32", win32_mod);
    text_mod.addImport("color", color_mod);

    const icon_mod = b.addModule("icon", .{
        .root_source_file = b.path("src/render/icon.zig"),
        .target = target,
        .optimize = optimize,
    });
    icon_mod.addImport("gl", gl_mod);
    icon_mod.addImport("win32", win32_mod);

    const render_mod = b.addModule("render", .{
        .root_source_file = b.path("src/render/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    render_mod.addImport("color", color_mod);
    render_mod.addImport("primitives", primitives_mod);
    render_mod.addImport("text", text_mod);
    render_mod.addImport("icon", icon_mod);
    render_mod.linkSystemLibrary("opengl32", .{});
    render_mod.linkSystemLibrary("gdi32", .{});
    render_mod.linkSystemLibrary("user32", .{});

    // ── Coarse-grained layer modules ──

    const platform_mod = b.addModule("platform", .{
        .root_source_file = b.path("src/platform/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    platform_mod.addImport("core", core_mod);
    platform_mod.addImport("win32", win32_mod);
    platform_mod.addImport("gl", gl_mod);
    platform_mod.addImport("window", window_mod);
    platform_mod.addImport("input", input_mod);
    platform_mod.addImport("timer", timer_mod);
    platform_mod.addImport("threading", threading_mod);
    platform_mod.addImport("http", http_mod);
    platform_mod.addImport("crypto", crypto_mod);
    platform_mod.addImport("file_io", file_io_mod);
    platform_mod.addImport("seqlock", seqlock_mod);
    platform_mod.addImport("screenshot", screenshot_mod);
    platform_mod.addImport("logging", logging_mod);
    platform_mod.addImport("png", png_mod);
    platform_mod.addImport("mcp", mcp_mod);
    for ([_][]const u8{
        "kernel32", "gdi32", "user32", "shell32",
        "opengl32", "winhttp", "bcrypt", "ws2_32",
    }) |lib| {
        platform_mod.linkSystemLibrary(lib, .{});
    }

    // ── Test step ──
    // Transport module tests will be wired here as modules are added.
    const test_step = b.step("test", "Run zpm package tests");

    // ── Granular modules (Layer 1: Transport) ──

    const udp_mod = b.addModule("udp", .{
        .root_source_file = b.path("src/transport/udp.zig"),
        .target = target,
        .optimize = optimize,
    });
    udp_mod.addImport("win32", win32_mod);
    udp_mod.linkSystemLibrary("ws2_32", .{});
    udp_mod.linkSystemLibrary("kernel32", .{});

    const packet_mod = b.addModule("packet", .{
        .root_source_file = b.path("src/transport/packet.zig"),
        .target = target,
        .optimize = optimize,
    });

    const transport_crypto_mod = b.addModule("transport_crypto", .{
        .root_source_file = b.path("src/transport/crypto.zig"),
        .target = target,
        .optimize = optimize,
    });
    transport_crypto_mod.addImport("win32", win32_mod);
    transport_crypto_mod.addImport("packet", packet_mod);
    transport_crypto_mod.addImport("crypto", crypto_mod);
    transport_crypto_mod.linkSystemLibrary("bcrypt", .{});
    transport_crypto_mod.linkSystemLibrary("secur32", .{});
    transport_crypto_mod.linkSystemLibrary("kernel32", .{});

    const recovery_mod = b.addModule("recovery", .{
        .root_source_file = b.path("src/transport/recovery.zig"),
        .target = target,
        .optimize = optimize,
    });
    recovery_mod.addImport("packet", packet_mod);

    const streams_mod = b.addModule("streams", .{
        .root_source_file = b.path("src/transport/streams.zig"),
        .target = target,
        .optimize = optimize,
    });
    streams_mod.addImport("packet", packet_mod);

    const datagram_mod = b.addModule("datagram", .{
        .root_source_file = b.path("src/transport/datagram.zig"),
        .target = target,
        .optimize = optimize,
    });
    datagram_mod.addImport("packet", packet_mod);

    const telemetry_mod = b.addModule("telemetry", .{
        .root_source_file = b.path("src/transport/telemetry.zig"),
        .target = target,
        .optimize = optimize,
    });

    const conn_mod = b.addModule("conn", .{
        .root_source_file = b.path("src/transport/conn.zig"),
        .target = target,
        .optimize = optimize,
    });
    conn_mod.addImport("win32", win32_mod);
    conn_mod.addImport("packet", packet_mod);
    conn_mod.addImport("transport_crypto", transport_crypto_mod);
    conn_mod.addImport("recovery", recovery_mod);
    conn_mod.addImport("streams", streams_mod);
    conn_mod.addImport("datagram", datagram_mod);
    conn_mod.addImport("telemetry", telemetry_mod);
    conn_mod.addImport("udp", udp_mod);
    conn_mod.linkSystemLibrary("ws2_32", .{});
    conn_mod.linkSystemLibrary("bcrypt", .{});
    conn_mod.linkSystemLibrary("secur32", .{});
    conn_mod.linkSystemLibrary("kernel32", .{});

    const scheduler_mod = b.addModule("scheduler", .{
        .root_source_file = b.path("src/transport/scheduler.zig"),
        .target = target,
        .optimize = optimize,
    });
    scheduler_mod.addImport("win32", win32_mod);
    scheduler_mod.addImport("packet", packet_mod);
    scheduler_mod.addImport("streams", streams_mod);
    scheduler_mod.addImport("datagram", datagram_mod);
    scheduler_mod.addImport("recovery", recovery_mod);
    scheduler_mod.addImport("transport_crypto", transport_crypto_mod);
    scheduler_mod.addImport("udp", udp_mod);
    scheduler_mod.addImport("telemetry", telemetry_mod);
    scheduler_mod.linkSystemLibrary("kernel32", .{});
    scheduler_mod.linkSystemLibrary("ws2_32", .{});
    scheduler_mod.linkSystemLibrary("bcrypt", .{});
    scheduler_mod.linkSystemLibrary("secur32", .{});

    const appmap_mod = b.addModule("appmap", .{
        .root_source_file = b.path("src/transport/appmap.zig"),
        .target = target,
        .optimize = optimize,
    });
    appmap_mod.addImport("streams", streams_mod);
    appmap_mod.addImport("datagram", datagram_mod);
    appmap_mod.addImport("packet", packet_mod);

    // ── Coarse-grained transport module ──

    const transport_mod = b.addModule("transport", .{
        .root_source_file = b.path("src/transport/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    transport_mod.addImport("udp", udp_mod);
    transport_mod.addImport("packet", packet_mod);
    transport_mod.addImport("transport_crypto", transport_crypto_mod);
    transport_mod.addImport("recovery", recovery_mod);
    transport_mod.addImport("streams", streams_mod);
    transport_mod.addImport("datagram", datagram_mod);
    transport_mod.addImport("scheduler", scheduler_mod);
    transport_mod.addImport("conn", conn_mod);
    transport_mod.addImport("telemetry", telemetry_mod);
    transport_mod.addImport("appmap", appmap_mod);
    for ([_][]const u8{
        "ws2_32", "bcrypt", "secur32", "kernel32",
    }) |lib| {
        transport_mod.linkSystemLibrary(lib, .{});
    }

    // ── Test wiring ──
    // Each test reuses the existing module to avoid duplicating the dependency graph.
    // A helper creates the test + run artifact once, then wires it to both the
    // aggregate "test" step and a standalone step.

    // udp tests
    const udp_tests = b.addTest(.{ .root_module = udp_mod });
    const udp_run = b.addRunArtifact(udp_tests);
    test_step.dependOn(&udp_run.step);

    // packet tests
    const packet_tests = b.addTest(.{ .root_module = packet_mod });
    const packet_run = b.addRunArtifact(packet_tests);
    test_step.dependOn(&packet_run.step);

    // transport_crypto tests
    const transport_crypto_tests = b.addTest(.{ .root_module = transport_crypto_mod });
    const transport_crypto_run = b.addRunArtifact(transport_crypto_tests);
    test_step.dependOn(&transport_crypto_run.step);

    // recovery tests
    const recovery_tests = b.addTest(.{ .root_module = recovery_mod });
    const recovery_run = b.addRunArtifact(recovery_tests);
    test_step.dependOn(&recovery_run.step);
    const recovery_test_step = b.step("test-recovery", "Run recovery module tests");
    recovery_test_step.dependOn(&recovery_run.step);

    // streams tests
    const streams_tests = b.addTest(.{ .root_module = streams_mod });
    streams_tests.stack_size = 16 * 1024 * 1024;
    const streams_run = b.addRunArtifact(streams_tests);
    test_step.dependOn(&streams_run.step);
    const streams_test_step = b.step("test-streams", "Run streams module tests");
    streams_test_step.dependOn(&streams_run.step);

    // datagram tests
    const datagram_tests = b.addTest(.{ .root_module = datagram_mod });
    const datagram_run = b.addRunArtifact(datagram_tests);
    test_step.dependOn(&datagram_run.step);
    const datagram_test_step = b.step("test-datagram", "Run datagram module tests");
    datagram_test_step.dependOn(&datagram_run.step);

    // telemetry tests
    const telemetry_tests = b.addTest(.{ .root_module = telemetry_mod });
    const telemetry_run = b.addRunArtifact(telemetry_tests);
    test_step.dependOn(&telemetry_run.step);
    const telemetry_test_step = b.step("test-telemetry", "Run telemetry module tests");
    telemetry_test_step.dependOn(&telemetry_run.step);

    // conn tests
    const conn_tests = b.addTest(.{ .root_module = conn_mod });
    conn_tests.stack_size = 16 * 1024 * 1024;
    const conn_run = b.addRunArtifact(conn_tests);
    test_step.dependOn(&conn_run.step);
    const conn_test_step = b.step("test-conn", "Run conn module tests");
    conn_test_step.dependOn(&conn_run.step);

    // scheduler tests
    const scheduler_tests = b.addTest(.{ .root_module = scheduler_mod });
    scheduler_tests.stack_size = 16 * 1024 * 1024;
    const scheduler_run = b.addRunArtifact(scheduler_tests);
    test_step.dependOn(&scheduler_run.step);
    const scheduler_test_step = b.step("test-scheduler", "Run scheduler module tests");
    scheduler_test_step.dependOn(&scheduler_run.step);

    // appmap tests
    const appmap_tests = b.addTest(.{ .root_module = appmap_mod });
    appmap_tests.stack_size = 16 * 1024 * 1024;
    const appmap_run = b.addRunArtifact(appmap_tests);
    test_step.dependOn(&appmap_run.step);
    const appmap_test_step = b.step("test-appmap", "Run appmap module tests");
    appmap_test_step.dependOn(&appmap_run.step);

    // no-allocator compliance property test
    const no_alloc_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/transport/no_alloc_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const no_alloc_run = b.addRunArtifact(no_alloc_tests);
    test_step.dependOn(&no_alloc_run.step);
    const no_alloc_test_step = b.step("test-no-alloc", "Run no-allocator compliance property test");
    no_alloc_test_step.dependOn(&no_alloc_run.step);

    // comptime buffer sizes compliance property test
    const comptime_sizes_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/transport/comptime_sizes_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    comptime_sizes_tests.stack_size = 16 * 1024 * 1024;
    const comptime_sizes_run = b.addRunArtifact(comptime_sizes_tests);
    test_step.dependOn(&comptime_sizes_run.step);
    const comptime_sizes_test_step = b.step("test-comptime-sizes", "Run comptime buffer sizes compliance property test");
    comptime_sizes_test_step.dependOn(&comptime_sizes_run.step);

    // layer hierarchy compliance property test
    const layer_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/transport/layer_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    layer_tests.stack_size = 16 * 1024 * 1024;
    const layer_run = b.addRunArtifact(layer_tests);
    test_step.dependOn(&layer_run.step);
    const layer_test_step = b.step("test-layer", "Run transport module layer hierarchy compliance property test");
    layer_test_step.dependOn(&layer_run.step);

    // domain-agnostic compliance property test
    const domain_agnostic_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/transport/domain_agnostic_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const domain_agnostic_run = b.addRunArtifact(domain_agnostic_tests);
    test_step.dependOn(&domain_agnostic_run.step);
    const domain_agnostic_test_step = b.step("test-domain-agnostic", "Run domain-agnostic compliance property test");
    domain_agnostic_test_step.dependOn(&domain_agnostic_run.step);

    // shared source files compliance property test
    const shared_source_mod = b.createModule(.{
        .root_source_file = b.path("src/transport/shared_source_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    shared_source_mod.addAnonymousImport("build_embed", .{
        .root_source_file = b.path("build_embed.zig"),
    });
    const shared_source_tests = b.addTest(.{
        .root_module = shared_source_mod,
    });
    shared_source_tests.stack_size = 16 * 1024 * 1024;
    const shared_source_run = b.addRunArtifact(shared_source_tests);
    test_step.dependOn(&shared_source_run.step);
    const shared_source_test_step = b.step("test-shared-source", "Run no shared source files compliance property test");
    shared_source_test_step.dependOn(&shared_source_run.step);

    // integration tests (full client-server handshake over loopback UDP)
    const integration_mod = b.createModule(.{
        .root_source_file = b.path("src/transport/integration_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    integration_mod.addImport("conn", conn_mod);
    integration_mod.addImport("telemetry", telemetry_mod);
    integration_mod.addImport("streams", streams_mod);
    integration_mod.addImport("transport_crypto", transport_crypto_mod);
    integration_mod.addImport("packet", packet_mod);
    integration_mod.addImport("recovery", recovery_mod);
    integration_mod.addImport("datagram", datagram_mod);
    integration_mod.addImport("udp", udp_mod);
    integration_mod.addImport("win32", win32_mod);
    integration_mod.addImport("appmap", appmap_mod);
    for ([_][]const u8{
        "ws2_32", "bcrypt", "secur32", "kernel32",
    }) |lib| {
        integration_mod.linkSystemLibrary(lib, .{});
    }
    const integration_tests = b.addTest(.{
        .root_module = integration_mod,
    });
    integration_tests.stack_size = 16 * 1024 * 1024;
    const integration_run = b.addRunArtifact(integration_tests);
    const integration_test_step = b.step("test-integration", "Run QUIC transport integration tests");
    integration_test_step.dependOn(&integration_run.step);

}
