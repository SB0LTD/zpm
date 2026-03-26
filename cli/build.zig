const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ── Transport modules (needed by registry.zig QuicTransportVtable) ──

    const packet_mod = b.createModule(.{ .root_source_file = b.path("../src/transport/packet.zig"), .target = target, .optimize = optimize });
    const win32_mod = b.createModule(.{ .root_source_file = b.path("../src/platform/win32.zig"), .target = target, .optimize = optimize });
    win32_mod.linkSystemLibrary("kernel32", .{});
    const crypto_mod = b.createModule(.{ .root_source_file = b.path("../src/platform/crypto.zig"), .target = target, .optimize = optimize });
    crypto_mod.addImport("win32", win32_mod);
    crypto_mod.linkSystemLibrary("bcrypt", .{});
    crypto_mod.linkSystemLibrary("kernel32", .{});
    const transport_crypto_mod = b.createModule(.{ .root_source_file = b.path("../src/transport/crypto.zig"), .target = target, .optimize = optimize });
    transport_crypto_mod.addImport("win32", win32_mod);
    transport_crypto_mod.addImport("packet", packet_mod);
    transport_crypto_mod.addImport("crypto", crypto_mod);
    transport_crypto_mod.linkSystemLibrary("bcrypt", .{});
    transport_crypto_mod.linkSystemLibrary("secur32", .{});
    transport_crypto_mod.linkSystemLibrary("kernel32", .{});
    const recovery_mod = b.createModule(.{ .root_source_file = b.path("../src/transport/recovery.zig"), .target = target, .optimize = optimize });
    recovery_mod.addImport("packet", packet_mod);
    const streams_mod = b.createModule(.{ .root_source_file = b.path("../src/transport/streams.zig"), .target = target, .optimize = optimize });
    streams_mod.addImport("packet", packet_mod);
    const datagram_mod = b.createModule(.{ .root_source_file = b.path("../src/transport/datagram.zig"), .target = target, .optimize = optimize });
    datagram_mod.addImport("packet", packet_mod);
    const telemetry_mod = b.createModule(.{ .root_source_file = b.path("../src/transport/telemetry.zig"), .target = target, .optimize = optimize });
    const udp_mod = b.createModule(.{ .root_source_file = b.path("../src/transport/udp.zig"), .target = target, .optimize = optimize });
    udp_mod.addImport("win32", win32_mod);
    udp_mod.linkSystemLibrary("ws2_32", .{});
    udp_mod.linkSystemLibrary("kernel32", .{});
    const conn_mod = b.createModule(.{ .root_source_file = b.path("../src/transport/conn.zig"), .target = target, .optimize = optimize });
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
    const appmap_mod = b.createModule(.{ .root_source_file = b.path("../src/transport/appmap.zig"), .target = target, .optimize = optimize });
    appmap_mod.addImport("streams", streams_mod);
    appmap_mod.addImport("datagram", datagram_mod);
    appmap_mod.addImport("packet", packet_mod);

    // ── zpm CLI executable ──
    const exe = b.addExecutable(.{ .name = "zpm", .root_module = b.createModule(.{
        .root_source_file = b.path("../src/pkg/zpm_main.zig"), .target = target, .optimize = optimize,
    }) });
    exe.root_module.addImport("conn", conn_mod);
    exe.root_module.addImport("appmap", appmap_mod);
    exe.root_module.addImport("streams", streams_mod);
    exe.root_module.addImport("datagram", datagram_mod);
    exe.root_module.addImport("telemetry", telemetry_mod);
    exe.root_module.addImport("win32", win32_mod);
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    b.step("run", "Run the zpm CLI").dependOn(&run_cmd.step);

    // ── Test step for pkg module tests (commands.zig, etc.) ──
    const test_step = b.step("test", "Run zpm CLI tests");
    const cmd_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("../src/pkg/commands.zig"), .target = target, .optimize = optimize,
    }) });
    cmd_tests.root_module.addImport("conn", conn_mod);
    cmd_tests.root_module.addImport("appmap", appmap_mod);
    cmd_tests.root_module.addImport("streams", streams_mod);
    cmd_tests.root_module.addImport("datagram", datagram_mod);
    cmd_tests.root_module.addImport("telemetry", telemetry_mod);
    cmd_tests.root_module.addImport("win32", win32_mod);
    cmd_tests.stack_size = 16 * 1024 * 1024;
    const cmd_run = b.addRunArtifact(cmd_tests);
    test_step.dependOn(&cmd_run.step);
}
