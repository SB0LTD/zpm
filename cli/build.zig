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

    // ── Transport modules (needed by registry.zig QuicTransportVtable) ──

    const packet_mod = b.createModule(.{ .root_source_file = b.path("../src/transport/packet.zig"), .target = target, .optimize = optimize });
    const win32_mod = b.createModule(.{ .root_source_file = b.path("../src/platform/win32.zig"), .target = target, .optimize = optimize });
    if (os_tag == .windows) win32_mod.linkSystemLibrary("kernel32", .{});

    const crypto_mod = b.createModule(.{ .root_source_file = b.path("../src/platform/crypto.zig"), .target = target, .optimize = optimize });
    crypto_mod.addImport("win32", win32_mod);
    if (os_tag == .windows) {
        crypto_mod.linkSystemLibrary("bcrypt", .{});
        crypto_mod.linkSystemLibrary("kernel32", .{});
    }

    const transport_crypto_mod = b.createModule(.{ .root_source_file = b.path("../src/transport/crypto.zig"), .target = target, .optimize = optimize });
    transport_crypto_mod.addImport("win32", win32_mod);
    transport_crypto_mod.addImport("packet", packet_mod);
    transport_crypto_mod.addImport("crypto", crypto_mod);
    if (os_tag == .windows) {
        transport_crypto_mod.linkSystemLibrary("bcrypt", .{});
        transport_crypto_mod.linkSystemLibrary("secur32", .{});
        transport_crypto_mod.linkSystemLibrary("kernel32", .{});
    }

    const recovery_mod = b.createModule(.{ .root_source_file = b.path("../src/transport/recovery.zig"), .target = target, .optimize = optimize });
    recovery_mod.addImport("packet", packet_mod);

    const streams_mod = b.createModule(.{ .root_source_file = b.path("../src/transport/streams.zig"), .target = target, .optimize = optimize });
    streams_mod.addImport("packet", packet_mod);

    const datagram_mod = b.createModule(.{ .root_source_file = b.path("../src/transport/datagram.zig"), .target = target, .optimize = optimize });
    datagram_mod.addImport("packet", packet_mod);

    const telemetry_mod = b.createModule(.{ .root_source_file = b.path("../src/transport/telemetry.zig"), .target = target, .optimize = optimize });

    const udp_mod = b.createModule(.{ .root_source_file = b.path("../src/transport/udp.zig"), .target = target, .optimize = optimize });
    udp_mod.addImport("win32", win32_mod);
    if (os_tag == .windows) {
        udp_mod.linkSystemLibrary("ws2_32", .{});
        udp_mod.linkSystemLibrary("kernel32", .{});
    }

    const conn_mod = b.createModule(.{ .root_source_file = b.path("../src/transport/conn.zig"), .target = target, .optimize = optimize });
    conn_mod.addImport("win32", win32_mod);
    conn_mod.addImport("packet", packet_mod);
    conn_mod.addImport("transport_crypto", transport_crypto_mod);
    conn_mod.addImport("recovery", recovery_mod);
    conn_mod.addImport("streams", streams_mod);
    conn_mod.addImport("datagram", datagram_mod);
    conn_mod.addImport("telemetry", telemetry_mod);
    conn_mod.addImport("udp", udp_mod);
    if (os_tag == .windows) {
        conn_mod.linkSystemLibrary("ws2_32", .{});
        conn_mod.linkSystemLibrary("bcrypt", .{});
        conn_mod.linkSystemLibrary("secur32", .{});
        conn_mod.linkSystemLibrary("kernel32", .{});
    }

    const appmap_mod = b.createModule(.{ .root_source_file = b.path("../src/transport/appmap.zig"), .target = target, .optimize = optimize });
    appmap_mod.addImport("streams", streams_mod);
    appmap_mod.addImport("datagram", datagram_mod);
    appmap_mod.addImport("packet", packet_mod);

    // ── PAL module (Platform Abstraction Layer) ──
    const pal_mod = b.createModule(.{ .root_source_file = b.path("pal.zig"), .target = target, .optimize = optimize });
    PlatformLibs.linkPlatform(pal_mod, os_tag);

    // ── zpm CLI executable ──
    const exe = b.addExecutable(.{ .name = "zpm", .root_module = b.createModule(.{
        .root_source_file = b.path("../src/pkg/zpm_main.zig"),
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
    if (b.args) |args| run_cmd.addArgs(args);
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

    // commands.zig (existing — includes most command handler tests)
    TestHelper.addPkgTest(b, test_step, b.path("../src/pkg/commands.zig"), target, optimize, conn_mod, appmap_mod, streams_mod, datagram_mod, telemetry_mod, win32_mod);

    // init.zig — project scaffolding tests
    TestHelper.addPkgTest(b, test_step, b.path("../src/pkg/init.zig"), target, optimize, conn_mod, appmap_mod, streams_mod, datagram_mod, telemetry_mod, win32_mod);

    // zon.zig — build.zig.zon manipulation tests
    TestHelper.addPkgTest(b, test_step, b.path("../src/pkg/zon.zig"), target, optimize, conn_mod, appmap_mod, streams_mod, datagram_mod, telemetry_mod, win32_mod);

    // cli.zig — argument parser tests
    TestHelper.addPkgTest(b, test_step, b.path("../src/pkg/cli.zig"), target, optimize, conn_mod, appmap_mod, streams_mod, datagram_mod, telemetry_mod, win32_mod);

    // names.zig — scoped name conversion tests
    TestHelper.addPkgTest(b, test_step, b.path("../src/pkg/names.zig"), target, optimize, conn_mod, appmap_mod, streams_mod, datagram_mod, telemetry_mod, win32_mod);

    // manifest.zig — package manifest parser tests
    TestHelper.addPkgTest(b, test_step, b.path("../src/pkg/manifest.zig"), target, optimize, conn_mod, appmap_mod, streams_mod, datagram_mod, telemetry_mod, win32_mod);

    // validator.zig — layer/constraint validation tests
    TestHelper.addPkgTest(b, test_step, b.path("../src/pkg/validator.zig"), target, optimize, conn_mod, appmap_mod, streams_mod, datagram_mod, telemetry_mod, win32_mod);

    // resolver.zig — dependency resolution tests
    TestHelper.addPkgTest(b, test_step, b.path("../src/pkg/resolver.zig"), target, optimize, conn_mod, appmap_mod, streams_mod, datagram_mod, telemetry_mod, win32_mod);

    // bootstrap.zig — Zig bootstrapper tests
    TestHelper.addPkgTest(b, test_step, b.path("../src/pkg/bootstrap.zig"), target, optimize, conn_mod, appmap_mod, streams_mod, datagram_mod, telemetry_mod, win32_mod);

    // official_packages.zig — official @zpm/ package map tests
    TestHelper.addPkgTest(b, test_step, b.path("../src/pkg/official_packages.zig"), target, optimize, conn_mod, appmap_mod, streams_mod, datagram_mod, telemetry_mod, win32_mod);
}
