// Canonical bounded Sig build graph for the ZPM CLI.
const sig_build = @import("sig_build");
const builtin = @import("builtin");

fn noopStep(ctx: *sig_build.Step_Context) sig_build.SigError!void {
    _ = ctx;
}

fn targetOsIsWindows(t: *const sig_build.Target_Triple) bool {
    const os = t.os[0..t.os_len];
    const w = "windows";
    if (os.len < w.len) return false;
    for (w, 0..) |c, i| {
        if (os[i] != c) return false;
    }
    return true;
}

fn importEntry(name: []const u8, path: []const u8) sig_build.Import_Entry {
    var entry: sig_build.Import_Entry = .{};
    @memcpy(entry.name[0..name.len], name);
    entry.name_len = name.len;
    @memcpy(entry.path[0..path.len], path);
    entry.path_len = path.len;
    return entry;
}

fn wire(ctx: *sig_build.Build_Context, module: sig_build.Module_Handle, name: []const u8, path: []const u8) !void {
    try ctx.addImport(module, name, path);
}

fn addPkgTest(
    ctx: *sig_build.Build_Context,
    aggregate: sig_build.Step_Handle,
    name: []const u8,
    source_path: []const u8,
    win32_path: []const u8,
    with_transport: bool,
) !void {
    const test_step = if (with_transport)
        try ctx.addTestStep(.{
            .name = name,
            .source_path = source_path,
            .imports = &.{
            importEntry("conn", "../src/transport/conn.sig"),
            importEntry("appmap", "../src/transport/appmap.sig"),
            importEntry("streams", "../src/transport/streams.sig"),
            importEntry("datagram", "../src/transport/datagram.sig"),
            importEntry("telemetry", "../src/transport/telemetry.sig"),
            importEntry("win32", win32_path),
            },
        })
    else
        try ctx.addTestStep(.{ .name = name, .source_path = source_path, .imports = &.{} });
    try ctx.addDependency(aggregate, test_step);
}

pub fn build(ctx: *sig_build.Build_Context) !void {
    // Select the platform backend by the *target* OS when cross-compiling
    // (-Dtarget=...), else by the host OS. The win32 module is Windows-only;
    // every other OS uses the POSIX/linux platform shim.
    const use_windows = if (ctx.target.arch_len > 0)
        targetOsIsWindows(&ctx.target)
    else
        builtin.os.tag == .windows;
    const win32_path = if (use_windows)
        "../src/platform/win32.sig"
    else
        "../src/transport/linux_platform.sig";

    _ = try ctx.addModule("packet", "../src/transport/packet.sig");
    _ = try ctx.addModule("win32", win32_path);
    const crypto = try ctx.addModule("crypto", "../src/platform/crypto.sig");
    try wire(ctx, crypto, "win32", win32_path);
    const transport_crypto = try ctx.addModule("transport_crypto", "../src/transport/crypto.sig");
    try wire(ctx, transport_crypto, "win32", win32_path);
    try wire(ctx, transport_crypto, "packet", "../src/transport/packet.sig");
    try wire(ctx, transport_crypto, "crypto", "../src/platform/crypto.sig");
    const recovery = try ctx.addModule("recovery", "../src/transport/recovery.sig");
    try wire(ctx, recovery, "packet", "../src/transport/packet.sig");
    const streams = try ctx.addModule("streams", "../src/transport/streams.sig");
    try wire(ctx, streams, "packet", "../src/transport/packet.sig");
    _ = try ctx.addModule("crypto_stream", "../src/transport/crypto_stream.sig");
    const datagram = try ctx.addModule("datagram", "../src/transport/datagram.sig");
    try wire(ctx, datagram, "packet", "../src/transport/packet.sig");
    _ = try ctx.addModule("telemetry", "../src/transport/telemetry.sig");
    const udp = try ctx.addModule("udp", "../src/transport/udp.sig");
    try wire(ctx, udp, "win32", win32_path);
    const conn = try ctx.addModule("conn", "../src/transport/conn.sig");
    try wire(ctx, conn, "win32", win32_path);
    try wire(ctx, conn, "packet", "../src/transport/packet.sig");
    try wire(ctx, conn, "transport_crypto", "../src/transport/crypto.sig");
    try wire(ctx, conn, "recovery", "../src/transport/recovery.sig");
    try wire(ctx, conn, "streams", "../src/transport/streams.sig");
    try wire(ctx, conn, "datagram", "../src/transport/datagram.sig");
    try wire(ctx, conn, "telemetry", "../src/transport/telemetry.sig");
    try wire(ctx, conn, "udp", "../src/transport/udp.sig");
    try wire(ctx, conn, "crypto_stream", "../src/transport/crypto_stream.sig");
    const appmap = try ctx.addModule("appmap", "../src/transport/appmap.sig");
    try wire(ctx, appmap, "streams", "../src/transport/streams.sig");
    try wire(ctx, appmap, "datagram", "../src/transport/datagram.sig");
    try wire(ctx, appmap, "packet", "../src/transport/packet.sig");
    _ = try ctx.addModule("pal", "pal.sig");

    // The executable is a first-class Sig compile step. Relative imports such
    // as commands.sig remain in the root module; named transport/PAL imports
    // are explicit and closure-resolved by sig_build.
    _ = try ctx.addCompileStep(.{
        .source_path = "../src/pkg/zpm_main.sig",
        .output_name = "zpm",
        .cache_dir = ctx.cache_dir[0..ctx.cache_dir_len],
        .optimize = ctx.optimize,
        .target = if (ctx.target.arch_len > 0) &ctx.target else null,
        .imports = &.{
            importEntry("conn", "../src/transport/conn.sig"),
            importEntry("appmap", "../src/transport/appmap.sig"),
            importEntry("streams", "../src/transport/streams.sig"),
            importEntry("datagram", "../src/transport/datagram.sig"),
            importEntry("telemetry", "../src/transport/telemetry.sig"),
            importEntry("win32", win32_path),
            importEntry("pal", "pal.sig"),
        },
        .compiler_path = "",
    });

    const test_all = try ctx.addStep("test", "Run all ZPM CLI package tests", &noopStep);
    try addPkgTest(ctx, test_all, "test-commands", "../src/pkg/commands.sig", win32_path, true);
    try addPkgTest(ctx, test_all, "test-init", "../src/pkg/init.sig", win32_path, false);
    try addPkgTest(ctx, test_all, "test-init-fs", "../src/pkg/init_fs_test.sig", win32_path, false);
    try addPkgTest(ctx, test_all, "test-zon", "../src/pkg/zon.sig", win32_path, false);
    try addPkgTest(ctx, test_all, "test-cli", "../src/pkg/cli.sig", win32_path, false);
    try addPkgTest(ctx, test_all, "test-names", "../src/pkg/names.sig", win32_path, false);
    try addPkgTest(ctx, test_all, "test-manifest", "../src/pkg/manifest.sig", win32_path, false);
    try addPkgTest(ctx, test_all, "test-validator", "../src/pkg/validator.sig", win32_path, false);
    try addPkgTest(ctx, test_all, "test-scanner", "../src/pkg/scanner.sig", win32_path, false);
    try addPkgTest(ctx, test_all, "test-resolver", "../src/pkg/resolver.sig", win32_path, false);
    try addPkgTest(ctx, test_all, "test-bootstrap", "../src/pkg/bootstrap.sig", win32_path, false);
    try addPkgTest(ctx, test_all, "test-official-packages", "../src/pkg/official_packages.sig", win32_path, false);
}
