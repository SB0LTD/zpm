// Entry point for the `zpm` CLI binary.
// Cross-platform via PAL (Platform Abstraction Layer).
// No allocator, no std I/O. All I/O through PAL.

const pal = @import("pal");
const cli = @import("cli.zig");
const commands = @import("commands.zig");
const registry = @import("registry.zig");
const bootstrap = @import("bootstrap.zig");
const conn_mod = @import("conn");
const appmap_mod = @import("appmap");
const streams_mod = @import("streams");
const datagram_mod = @import("datagram");
const telemetry_mod = @import("telemetry");

const VERSION = "0.1.0";
const DEFAULT_REGISTRY = "https://registry.zpm.dev";

// ── PAL-backed vtable callbacks ──

fn readFileCb(path: []const u8, buf: []u8) ?[]const u8 {
    return pal.palReadFileCb(path, buf);
}

fn writeFileCb(path: []const u8, data: []const u8) bool {
    return pal.palWriteFileCb(path, data);
}

fn createDirCb(path: []const u8) bool {
    return pal.palCreateDirCb(path);
}

fn dirExistsCb(path: []const u8) bool {
    return pal.palDirExistsCb(path);
}

fn dirIsEmptyCb(path: []const u8) bool {
    return pal.palDirIsEmptyCb(path);
}

fn removeDirCb(path: []const u8) bool {
    return pal.palRemoveDirCb(path);
}
// ── PAL-backed HTTP vtable ──

fn palHttpGet(url: []const u8, response_buf: []u8) registry.GetResult {
    return switch (pal.httpGet(url, response_buf)) {
        .ok => |body| .{ .ok = .{ .body = body } },
        .err => .{ .err = error.ConnectionFailed },
    };
}

fn palHttpPost(url: []const u8, body: []const u8, response_buf: []u8) registry.PostResult {
    return switch (pal.httpPost(url, body, response_buf)) {
        .ok => |resp_body| .{ .ok = .{ .status = 200, .body = resp_body } },
        .err => .{ .err = error.ConnectionFailed },
    };
}

const pal_http_vtable = registry.HttpVtable{ .get = &palHttpGet, .post = &palHttpPost };

// ── PAL-backed bootstrap vtable ──

fn palBootExec(cmd: []const u8, stdout_buf: []u8) ?bootstrap.ExecResult {
    const result = pal.exec(cmd, stdout_buf) orelse return null;
    return .{ .exit_code = result.exit_code, .stdout = result.stdout };
}

fn palBootDownload(url: []const u8, dest_path: []const u8) bool {
    // Use HTTP GET to download, then write to file
    var dl_buf: [4 * 1024 * 1024]u8 = undefined;
    return switch (pal.httpGet(url, &dl_buf)) {
        .ok => |body| pal.palWriteFileCb(dest_path, body),
        .err => false,
    };
}

fn palBootExtract(_: []const u8, _: []const u8) bool {
    // Extraction requires platform-specific archive handling — stub for now
    return false;
}

const pal_boot_vtable = bootstrap.BootstrapVtable{
    .exec = &palBootExec,
    .download = &palBootDownload,
    .extract = &palBootExtract,
    .print = &pal.writeStdout,
};
// ── Cross-platform argument retrieval ──

const builtin = @import("builtin");
const os_tag = builtin.os.tag;

var arg_store: [64][256]u8 = undefined;
var arg_ptrs: [64][]const u8 = undefined;

fn getArgs() []const []const u8 {
    if (os_tag == .windows) {
        return getArgsWindows();
    } else {
        return getArgsPosix();
    }
}

// Windows: use CommandLineToArgvW
const LPCWSTR = [*:0]const u16;
const win32_args = if (os_tag == .windows) struct {
    extern "kernel32" fn GetCommandLineW() callconv(.c) LPCWSTR;
    extern "shell32" fn CommandLineToArgvW(LPCWSTR, *c_int) callconv(.c) ?[*][*:0]const u16;
    extern "kernel32" fn LocalFree(?*anyopaque) callconv(.c) ?*anyopaque;
} else struct {};

fn getArgsWindows() []const []const u8 {
    var argc: c_int = 0;
    const argv = win32_args.CommandLineToArgvW(win32_args.GetCommandLineW(), &argc) orelse return &.{};
    defer _ = win32_args.LocalFree(@ptrCast(argv));
    const cnt: usize = @intCast(argc);
    if (cnt <= 1) return &.{};
    var n: usize = 0;
    for (1..cnt) |i| {
        const w = argv[i];
        var len: usize = 0;
        while (len < 255 and w[len] != 0) : (len += 1) {
            arg_store[n][len] = @truncate(w[len]);
        }
        arg_ptrs[n] = arg_store[n][0..len];
        n += 1;
        if (n >= 64) break;
    }
    return arg_ptrs[0..n];
}

// POSIX: use /proc/self/cmdline on Linux, or __argc/__argv pattern
// For simplicity, we use a C-compatible main and store args at startup.
// Since Zig's entry point calls main(), we use @import("std").os for args.
// Actually, for zero-alloc we'll use the same approach as the original but
// with POSIX-compatible arg reading.

var posix_argc: usize = 0;
var posix_argv_set: bool = false;

fn getArgsPosix() []const []const u8 {
    // Read from /proc/self/cmdline on Linux, or use a stub
    if (os_tag == .linux) {
        return readProcCmdline();
    }
    // macOS: read from /proc not available, use _NSGetArgc/_NSGetArgv
    if (os_tag == .macos) {
        return getMacArgs();
    }
    return &.{};
}

fn readProcCmdline() []const []const u8 {
    var cmdline_buf: [4096]u8 = undefined;
    const content = pal.readFile("/proc/self/cmdline", &cmdline_buf) catch return &.{};
    // Parse null-separated args, skip argv[0]
    var n: usize = 0;
    var start: usize = 0;
    var skip_first = true;
    for (content, 0..) |c, idx| {
        if (c == 0) {
            if (skip_first) {
                skip_first = false;
            } else if (idx > start) {
                const len = idx - start;
                if (n < 64 and len < 256) {
                    @memcpy(arg_store[n][0..len], content[start..idx]);
                    arg_ptrs[n] = arg_store[n][0..len];
                    n += 1;
                }
            }
            start = idx + 1;
        }
    }
    return arg_ptrs[0..n];
}

const mac_args = if (os_tag == .macos) struct {
    extern "c" fn _NSGetArgc() *c_int;
    extern "c" fn _NSGetArgv() *[*][*:0]const u8;
} else struct {};

fn getMacArgs() []const []const u8 {
    const argc_ptr = mac_args._NSGetArgc();
    const argv_ptr = mac_args._NSGetArgv();
    const argc: usize = @intCast(argc_ptr.*);
    const argv = argv_ptr.*;
    if (argc <= 1) return &.{};
    var n: usize = 0;
    for (1..argc) |i| {
        const arg = argv[i];
        var len: usize = 0;
        while (len < 255 and arg[len] != 0) : (len += 1) {
            arg_store[n][len] = arg[len];
        }
        arg_ptrs[n] = arg_store[n][0..len];
        n += 1;
        if (n >= 64) break;
    }
    return arg_ptrs[0..n];
}
// ── Entry Point ──

pub fn main() void {
    const args = getArgs();
    switch (cli.parse(args)) {
        .err => |e| {
            pal.writeStderr("error: ");
            pal.writeStderr(e.message);
            pal.writeStderr("\n");
            if (e.suggestion) |s| {
                pal.writeStderr("did you mean: ");
                pal.writeStderr(s);
                pal.writeStderr("?\n");
            }
        },
        .ok => |parsed| dispatch(&parsed),
    }
}

fn dispatch(parsed: *const cli.ParsedArgs) void {
    const cmd = parsed.command orelse .help;
    if (cmd == .help) {
        printHelp();
        return;
    }
    if (cmd == .version) {
        pal.writeStdout("zpm v" ++ VERSION ++ "\n");
        return;
    }

    // Select transport: QUIC or default HTTP
    var quic_vtable: registry.QuicTransportVtable = undefined;
    const use_quic = if (parsed.transport) |t| eqlStr(t, "quic") else false;
    const selected_http: registry.HttpVtable = if (use_quic) blk: {
        // Wire the QUIC transport vtable through conn + appmap modules.
        // The vtable routes resolve/publish/search through the QUIC connection.
        //
        // TODO: Full connection setup (UDP socket bind, QUIC handshake to
        // registry server) requires PAL UDP operations and a server address.
        // For now, we create the vtable structure so the wiring is complete,
        // but the connection will fail at the transport level until the
        // socket bind + handshake is implemented.
        //
        // Once PAL UDP is wired:
        //   1. Bind a UDP socket via pal
        //   2. Create conn.Connection.initClient(registry_addr)
        //   3. Drive conn.tick() in a loop for the TLS handshake
        //   4. Pass the connected conn + appmap to QuicTransportVtable

        // For now, create a vtable with null pointers — the QUIC get/post
        // functions check for null conn and return ConnectionFailed gracefully.
        quic_vtable = registry.QuicTransportVtable{
            .conn = null,
            .appmap = null,
        };
        // Activate stores conn/appmap into module-level state for bare fn ptrs
        quic_vtable.activate();
        pal.writeStderr("quic transport: connection setup pending (socket bind + handshake not yet wired)\n");
        pal.writeStderr("quic transport: vtable wired — will return ConnectionFailed until handshake completes\n");
        break :blk registry.QuicTransportVtable.asHttpVtable();
    } else pal_http_vtable;

    const reg = registry.RegistryClient{
        .base_url = parsed.flags.registry_url orelse DEFAULT_REGISTRY,
        .offline = parsed.flags.offline,
        .http = selected_http,
    };
    const boot = bootstrap.ZigBootstrapper{
        .vtable = pal_boot_vtable,
        .offline = parsed.flags.offline,
        .auto_update = parsed.yes,
    };
    const ctx = commands.CommandContext{
        .registry_client = &reg,
        .stdout = &pal.writeStdout,
        .stderr = &pal.writeStderr,
        .read_file = &readFileCb,
        .write_file = &writeFileCb,
        .bootstrapper = &boot,
        .init_create_dir = &createDirCb,
        .init_write_file = &writeFileCb,
        .init_dir_exists = &dirExistsCb,
        .init_dir_is_empty = &dirIsEmptyCb,
        .init_remove_dir = &removeDirCb,
        .init_print = &pal.writeStdout,
    };
    _ = switch (cmd) {
        .init => commands.initCmd(&ctx, parsed),
        .install => commands.install(&ctx, parsed),
        .uninstall => commands.uninstall(&ctx, parsed),
        .list => commands.listCmd(&ctx, parsed),
        .search => commands.searchCmd(&ctx, parsed),
        .publish => commands.publishCmd(&ctx, parsed),
        .validate => commands.validateCmd(&ctx, parsed),
        .update => commands.update(&ctx, parsed),
        .doctor => commands.doctorCmd(&ctx, parsed),
        .run => commands.runCmd(&ctx, parsed),
        .build => commands.buildCmd(&ctx, parsed),
        .help, .version => unreachable,
    };
}

fn eqlStr(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (ca != cb) return false;
    }
    return true;
}

fn printHelp() void {
    pal.writeStdout("zpm v" ++ VERSION ++ " — package manager for the zpm ecosystem\n\nUsage: zpm <command> [options] [args]\n\nCommands:\n  init            Scaffold a new project\n  install (i)     Install packages\n  uninstall (rm)  Remove packages\n  list (ls)       List installed packages\n  search          Search the registry\n  publish (pub)   Publish a package\n  validate (val)  Validate for publishing\n  update (up)     Update packages\n  doctor          Check environment health\n  run             Build and run\n  build           Build project\n\nFlags:\n  -v  --verbose   Detailed output\n  -q  --quiet     Suppress non-error output\n  --offline       No network requests\n  --registry URL  Override registry URL\n  -h  --help      Show help\n  -V  --version   Show version\n");
}
