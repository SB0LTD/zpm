const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const os_tag = target.result.os.tag;

    // ── Helper: link platform-specific system libraries to a module ──
    const PlatformLibs = struct {
        fn linkWin32(mod: *std.Build.Module) void {
            for ([_][]const u8{ "kernel32", "ws2_32", "bcrypt", "secur32", "winhttp", "shell32" }) |lib| {
                mod.linkSystemLibrary(lib, .{});
            }
        }
        fn linkMacos(mod: *std.Build.Module) void {
            mod.linkFramework("Security", .{});
            mod.linkFramework("SystemConfiguration", .{});
            mod.linkFramework("CoreFoundation", .{});
        }
        fn linkLinux(mod: *std.Build.Module) void {
            // Zig's built-in TLS handles most cases; link OpenSSL for completeness
            mod.linkSystemLibrary("ssl", .{});
            mod.linkSystemLibrary("crypto", .{});
        }
        fn linkPlatform(mod: *std.Build.Module, os: std.Target.Os.Tag) void {
            switch (os) {
                .windows => linkWin32(mod),
                .macos => linkMacos(mod),
                .linux => linkLinux(mod),
                else => {},
            }
        }
    };

    // ── Transport modules (needed by registry.sig QuicTransportVtable) ──

    const packet_mod = b.createModule(.{ .root_source_file = b.path("../src/transport/packet.sig"), .target = target, .optimize = optimize });
    const win32_mod = b.createModule(.{ .root_source_file = if (os_tag == .windows) b.path("../src/platform/win32.sig") else b.path("../src/transport/linux_platform.sig"), .target = target, .optimize = optimize });
    if (os_tag == .windows) win32_mod.linkSystemLibrary("kernel32", .{});

    const crypto_mod = b.createModule(.{ .root_source_file = b.path("../src/platform/crypto.sig"), .target = target, .optimize = optimize });
    crypto_mod.addImport("win32", win32_mod);
    if (os_tag == .windows) {
        crypto_mod.linkSystemLibrary("bcrypt", .{});
        crypto_mod.linkSystemLibrary("kernel32", .{});
    }

    const transport_crypto_mod = b.createModule(.{ .root_source_file = b.path("../src/transport/crypto.sig"), .target = target, .optimize = optimize });
    transport_crypto_mod.addImport("win32", win32_mod);
    transport_crypto_mod.addImport("packet", packet_mod);
    transport_crypto_mod.addImport("crypto", crypto_mod);
    if (os_tag == .windows) {
        transport_crypto_mod.linkSystemLibrary("bcrypt", .{});
        transport_crypto_mod.linkSystemLibrary("secur32", .{});
        transport_crypto_mod.linkSystemLibrary("kernel32", .{});
    }

    const recovery_mod = b.createModule(.{ .root_source_file = b.path("../src/transport/recovery.sig"), .target = target, .optimize = optimize });
    recovery_mod.addImport("packet", packet_mod);
    const crypto_stream_mod = b.createModule(.{ .root_source_file = b.path("../src/transport/crypto_stream.sig"), .target = target, .optimize = optimize });

    const streams_mod = b.createModule(.{ .root_source_file = b.path("../src/transport/streams.sig"), .target = target, .optimize = optimize });
    streams_mod.addImport("packet", packet_mod);

    const datagram_mod = b.createModule(.{ .root_source_file = b.path("../src/transport/datagram.sig"), .target = target, .optimize = optimize });
    datagram_mod.addImport("packet", packet_mod);

    const telemetry_mod = b.createModule(.{ .root_source_file = b.path("../src/transport/telemetry.sig"), .target = target, .optimize = optimize });

    const udp_mod = b.createModule(.{ .root_source_file = b.path("../src/transport/udp.sig"), .target = target, .optimize = optimize });
    udp_mod.addImport("win32", win32_mod);
    if (os_tag == .windows) {
        udp_mod.linkSystemLibrary("ws2_32", .{});
        udp_mod.linkSystemLibrary("kernel32", .{});
    }

    const conn_mod = b.createModule(.{ .root_source_file = b.path("../src/transport/conn.sig"), .target = target, .optimize = optimize });
    conn_mod.addImport("win32", win32_mod);
    conn_mod.addImport("packet", packet_mod);
    conn_mod.addImport("transport_crypto", transport_crypto_mod);
    conn_mod.addImport("recovery", recovery_mod);
    conn_mod.addImport("streams", streams_mod);
    conn_mod.addImport("datagram", datagram_mod);
    conn_mod.addImport("telemetry", telemetry_mod);
    conn_mod.addImport("udp", udp_mod);
    conn_mod.addImport("crypto_stream", crypto_stream_mod);   
    if (os_tag == .windows) {
        conn_mod.linkSystemLibrary("ws2_32", .{});
        conn_mod.linkSystemLibrary("bcrypt", .{});
        conn_mod.linkSystemLibrary("secur32", .{});
        conn_mod.linkSystemLibrary("kernel32", .{});
    }

    const appmap_mod = b.createModule(.{ .root_source_file = b.path("../src/transport/appmap.sig"), .target = target, .optimize = optimize });
    appmap_mod.addImport("streams", streams_mod);
    appmap_mod.addImport("datagram", datagram_mod);
    appmap_mod.addImport("packet", packet_mod);

    // ── PAL module (Platform Abstraction Layer) ──
    const pal_mod = b.createModule(.{ .root_source_file = b.path("pal.sig"), .target = target, .optimize = optimize });
    PlatformLibs.linkPlatform(pal_mod, os_tag);
        pal_mod.link_libc = true;

    // ── zpm CLI executable ──
    const exe = b.addExecutable(.{ .name = "zpm", .root_module = b.createModule(.{
        .root_source_file = b.path("../src/pkg/zpm_main.sig"),
        .target = target,
        .optimize = optimize,
    }) });
    exe.root_module.addImport("conn", conn_mod);
    exe.root_module.addImport("appmap", appmap_mod);
    exe.root_module.addImport("streams", streams_mod);
    exe.root_module.addImport("datagram", datagram_mod);
    exe.root_module.addImport("telemetry", telemetry_mod);
    exe.root_module.addImport("win32", win32_mod);
    exe.root_module.addImport("pal", pal_mod);
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
// NOTE: Sig's std.Build has no `args` field (upstream Zig's CLI passthrough after `--`).
    // Run-step argument forwarding is unavailable under sig build.
    b.step("run", "Run the zpm CLI").dependOn(&run_cmd.step);

    // ── Test step ──
    const test_step = b.step("test", "Run zpm CLI tests");

    // Helper to create a pkg module test with transport imports wired
    const TestHelper = struct {
        fn addPkgTest(
            b_: *std.Build,
            step: *std.Build.Step,
            src: std.Build.LazyPath,
            tgt: std.Build.ResolvedTarget,
            opt: std.builtin.OptimizeMode,
            conn_m: *std.Build.Module,
            appmap_m: *std.Build.Module,
            streams_m: *std.Build.Module,
            datagram_m: *std.Build.Module,
            telemetry_m: *std.Build.Module,
            win32_m: *std.Build.Module,
        ) void {
            const t = b_.addTest(.{ .root_module = b_.createModule(.{
                .root_source_file = src,
                .target = tgt,
                .optimize = opt,
            }) });
            t.root_module.addImport("conn", conn_m);
            t.root_module.addImport("appmap", appmap_m);
            t.root_module.addImport("streams", streams_m);
            t.root_module.addImport("datagram", datagram_m);
            t.root_module.addImport("telemetry", telemetry_m);
            t.root_module.addImport("win32", win32_m);
            t.stack_size = 16 * 1024 * 1024;
            const run = b_.addRunArtifact(t);
            step.dependOn(&run.step);
        }
    };

    // commands.sig (existing — includes most command handler tests)
    TestHelper.addPkgTest(b, test_step, b.path("../src/pkg/commands.sig"), target, optimize, conn_mod, appmap_mod, streams_mod, datagram_mod, telemetry_mod, win32_mod);

    // init.sig — project scaffolding tests
    TestHelper.addPkgTest(b, test_step, b.path("../src/pkg/init.sig"), target, optimize, conn_mod, appmap_mod, streams_mod, datagram_mod, telemetry_mod, win32_mod);

    // zon.sig — build.sig.zon manipulation tests
    TestHelper.addPkgTest(b, test_step, b.path("../src/pkg/zon.sig"), target, optimize, conn_mod, appmap_mod, streams_mod, datagram_mod, telemetry_mod, win32_mod);

    // cli.sig — argument parser tests
    TestHelper.addPkgTest(b, test_step, b.path("../src/pkg/cli.sig"), target, optimize, conn_mod, appmap_mod, streams_mod, datagram_mod, telemetry_mod, win32_mod);

    // names.sig — scoped name conversion tests
    TestHelper.addPkgTest(b, test_step, b.path("../src/pkg/names.sig"), target, optimize, conn_mod, appmap_mod, streams_mod, datagram_mod, telemetry_mod, win32_mod);

    // manifest.sig — package manifest parser tests
    TestHelper.addPkgTest(b, test_step, b.path("../src/pkg/manifest.sig"), target, optimize, conn_mod, appmap_mod, streams_mod, datagram_mod, telemetry_mod, win32_mod);

    // validator.sig — layer/constraint validation tests
    TestHelper.addPkgTest(b, test_step, b.path("../src/pkg/validator.sig"), target, optimize, conn_mod, appmap_mod, streams_mod, datagram_mod, telemetry_mod, win32_mod);

    // resolver.sig — dependency resolution tests
    TestHelper.addPkgTest(b, test_step, b.path("../src/pkg/resolver.sig"), target, optimize, conn_mod, appmap_mod, streams_mod, datagram_mod, telemetry_mod, win32_mod);

    // bootstrap.sig — Zig bootstrapper tests
    TestHelper.addPkgTest(b, test_step, b.path("../src/pkg/bootstrap.sig"), target, optimize, conn_mod, appmap_mod, streams_mod, datagram_mod, telemetry_mod, win32_mod);

    // official_packages.sig — official @zpm/ package map tests
    TestHelper.addPkgTest(b, test_step, b.path("../src/pkg/official_packages.sig"), target, optimize, conn_mod, appmap_mod, streams_mod, datagram_mod, telemetry_mod, win32_mod);
}
