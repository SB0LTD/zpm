// Entry point for the `zpm` CLI binary.
// Cross-platform via PAL (Platform Abstraction Layer).
// No allocator, no std I/O. All I/O through PAL.

const pal = @import("pal");
const process = @import("sig_process");
const cli = @import("cli.sig");
const commands = @import("commands.sig");
const registry = @import("registry.sig");
const bootstrap = @import("bootstrap.sig");
const conn_mod = @import("conn");
const appmap_mod = @import("appmap");
const streams_mod = @import("streams");
const datagram_mod = @import("datagram");
const telemetry_mod = @import("telemetry");

const VERSION = "0.3.0";
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

// Minimal startup exposes native argv without initializing an allocator.
const std = @import("std");
var arg_store: [process.MAX_CMD_ARGS][process.MAX_ARG_LEN]u8 = undefined;
var arg_ptrs: [process.MAX_CMD_ARGS][]const u8 = undefined;
var decoded_arg: [98_304]u8 = undefined;
var build_command: process.Command_Buffer = .{};

fn getArgs(init: std.process.Init.Minimal) []const []const u8 {
    var iterator = process.Argv_Iterator.init(init.args.vector, &decoded_arg);
    _ = iterator.next() catch process.exit(2);
    var n: usize = 0;
    while (iterator.next() catch process.exit(2)) |arg| {
        if (n == arg_ptrs.len or arg.len > arg_store[n].len) {
            pal.writeStderr("zpm: argument capacity exceeded\n");
            process.exit(2);
        }
        // Windows reuses its decoding buffer. Copy before advancing,
        // retaining empty arguments and failing on overflow, never truncating.
        @memcpy(arg_store[n][0..arg.len], arg);
        arg_ptrs[n] = arg_store[n][0..arg.len];
        n += 1;
    }
    return arg_ptrs[0..n];
}

pub fn main(init: std.process.Init.Minimal) void {
    const args = getArgs(init);
    // Build flags and arguments belong to Sig, including `--` and unknown
    // future flags. Forward their exact argv before ZPM's package parser.
    if (args.len != 0 and (eqlStr(args[0], "build") or eqlStr(args[0], "run")))
        process.exit(delegateBuild(eqlStr(args[0], "run"), args[1..]) catch |failure| {
            pal.writeStderr("zpm: cannot execute Sig build: ");
            pal.writeStderr(@errorName(failure));
            pal.writeStderr("\nSet SIG to a working SB0LTD/Sig executable.\n");
            process.exit(127);
        });
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
            process.exit(2);
        },
        .ok => |parsed| dispatch(&parsed),
    }
}

fn delegateBuild(run: bool, args: []const []const u8) !u8 {
    var compiler_buffer: [4096]u8 = undefined;
    const configured = try process.getenv("SIG", &compiler_buffer);
    const compiler = if (configured) |value| (if (value.len != 0) value else "sig") else "sig";
    build_command = .{};
    try build_command.appendArg(compiler);
    try build_command.appendArg("build");
    if (run) try build_command.appendArg("run");
    for (args) |argument| try build_command.appendArg(argument);
    var child = try process.spawn(.{}, &build_command, .{});
    return switch (try child.wait(.{})) {
        .exited => |code| code,
        .signal => |signal| process.signalToExitCode(signal),
        else => 1,
    };
}

fn buildCb(run: bool, args: []const []const u8) u8 {
    return delegateBuild(run, args) catch 127;
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
    const boot = bootstrap.SigBootstrapper{
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
        .build = &buildCb,
        .init_create_dir = &createDirCb,
        .init_write_file = &writeFileCb,
        .init_dir_exists = &dirExistsCb,
        .init_dir_is_empty = &dirIsEmptyCb,
        .init_remove_dir = &removeDirCb,
        .init_print = &pal.writeStdout,
    };
    const result = switch (cmd) {
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
    if (result != .success) process.exit(1);
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
