// Entry point for the `zpm` CLI binary.
// No allocator, no std I/O. Win32 externs only.

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

const HANDLE = *opaque {};
const DWORD = u32;
const BOOL = c_int;
const LPCWSTR = [*:0]const u16;
const INVALID_HANDLE_VALUE: HANDLE = @ptrFromInt(@as(usize, @bitCast(@as(isize, -1))));
const STD_OUTPUT_HANDLE: DWORD = @bitCast(@as(i32, -11));
const STD_ERROR_HANDLE: DWORD = @bitCast(@as(i32, -12));
const GENERIC_READ: DWORD = 0x80000000;
const GENERIC_WRITE: DWORD = 0x40000000;
const FILE_SHARE_READ: DWORD = 1;
const OPEN_EXISTING: DWORD = 3;
const CREATE_ALWAYS: DWORD = 2;
const INVALID_FILE_ATTRIBUTES: DWORD = 0xFFFFFFFF;
const FILE_ATTRIBUTE_DIRECTORY: DWORD = 0x10;

extern "kernel32" fn GetStdHandle(DWORD) callconv(.c) HANDLE;
extern "kernel32" fn WriteFile(HANDLE, [*]const u8, DWORD, ?*DWORD, ?*anyopaque) callconv(.c) BOOL;
extern "kernel32" fn GetCommandLineW() callconv(.c) LPCWSTR;
extern "kernel32" fn CreateFileA([*:0]const u8, DWORD, DWORD, ?*anyopaque, DWORD, DWORD, ?HANDLE) callconv(.c) HANDLE;
extern "kernel32" fn ReadFile(HANDLE, [*]u8, DWORD, *DWORD, ?*anyopaque) callconv(.c) BOOL;
extern "kernel32" fn CloseHandle(HANDLE) callconv(.c) BOOL;
extern "kernel32" fn CreateDirectoryA([*:0]const u8, ?*anyopaque) callconv(.c) BOOL;
extern "kernel32" fn GetFileAttributesA([*:0]const u8) callconv(.c) DWORD;
extern "kernel32" fn RemoveDirectoryA([*:0]const u8) callconv(.c) BOOL;
extern "shell32" fn CommandLineToArgvW(LPCWSTR, *c_int) callconv(.c) ?[*][*:0]const u16;
extern "kernel32" fn LocalFree(?*anyopaque) callconv(.c) ?*anyopaque;

fn writeStdout(data: []const u8) void {
    _ = WriteFile(GetStdHandle(STD_OUTPUT_HANDLE), data.ptr, @intCast(data.len), null, null);
}
fn writeStderr(data: []const u8) void {
    _ = WriteFile(GetStdHandle(STD_ERROR_HANDLE), data.ptr, @intCast(data.len), null, null);
}

fn toZ(path: []const u8, buf: *[512]u8) ?[*:0]const u8 {
    if (path.len >= 512) return null;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    return @ptrCast(buf[0..path.len :0]);
}
fn readFileCb(path: []const u8, buf: []u8) ?[]const u8 {
    var z: [512]u8 = undefined;
    const p = toZ(path, &z) orelse return null;
    const h = CreateFileA(p, GENERIC_READ, FILE_SHARE_READ, null, OPEN_EXISTING, 0, null);
    if (h == INVALID_HANDLE_VALUE) return null;
    defer _ = CloseHandle(h);
    var n: DWORD = 0;
    if (ReadFile(h, buf.ptr, @intCast(buf.len), &n, null) == 0) return null;
    return buf[0..n];
}
fn writeFileCb(path: []const u8, data: []const u8) bool {
    var z: [512]u8 = undefined;
    const p = toZ(path, &z) orelse return false;
    const h = CreateFileA(p, GENERIC_WRITE, 0, null, CREATE_ALWAYS, 0, null);
    if (h == INVALID_HANDLE_VALUE) return false;
    defer _ = CloseHandle(h);
    _ = WriteFile(h, data.ptr, @intCast(data.len), null, null);
    return true;
}
fn createDirCb(path: []const u8) bool {
    var z: [512]u8 = undefined;
    return CreateDirectoryA(toZ(path, &z) orelse return false, null) != 0;
}
fn dirExistsCb(path: []const u8) bool {
    var z: [512]u8 = undefined;
    const a = GetFileAttributesA(toZ(path, &z) orelse return false);
    return a != INVALID_FILE_ATTRIBUTES and (a & FILE_ATTRIBUTE_DIRECTORY) != 0;
}
fn dirIsEmptyCb(_: []const u8) bool { return true; }
fn removeDirCb(path: []const u8) bool {
    var z: [512]u8 = undefined;
    return RemoveDirectoryA(toZ(path, &z) orelse return false) != 0;
}

fn httpGet(_: []const u8, _: []u8) registry.GetResult { return .{ .err = error.ConnectionFailed }; }
fn httpPost(_: []const u8, _: []const u8, _: []u8) registry.PostResult { return .{ .err = error.ConnectionFailed }; }
const http_vtable = registry.HttpVtable{ .get = &httpGet, .post = &httpPost };

fn bootExec(_: []const u8, _: []u8) ?bootstrap.ExecResult { return null; }
fn bootDownload(_: []const u8, _: []const u8) bool { return false; }
fn bootExtract(_: []const u8, _: []const u8) bool { return false; }
const boot_vtable = bootstrap.BootstrapVtable{ .exec = &bootExec, .download = &bootDownload, .extract = &bootExtract, .print = &writeStdout };

// Stack-backed allocator removed — all APIs are now zero-allocation

var arg_store: [64][256]u8 = undefined;
var arg_ptrs: [64][]const u8 = undefined;
fn getArgs() []const []const u8 {
    var argc: c_int = 0;
    const argv = CommandLineToArgvW(GetCommandLineW(), &argc) orelse return &.{};
    defer _ = LocalFree(@ptrCast(argv));
    const cnt: usize = @intCast(argc);
    if (cnt <= 1) return &.{};
    var n: usize = 0;
    for (1..cnt) |i| {
        const w = argv[i];
        var len: usize = 0;
        while (len < 255 and w[len] != 0) : (len += 1) { arg_store[n][len] = @truncate(w[len]); }
        arg_ptrs[n] = arg_store[n][0..len];
        n += 1;
        if (n >= 64) break;
    }
    return arg_ptrs[0..n];
}

pub fn main() void {
    const args = getArgs();
    switch (cli.parse(args)) {
        .err => |e| {
            writeStderr("error: ");
            writeStderr(e.message);
            writeStderr("\n");
            if (e.suggestion) |s| { writeStderr("did you mean: "); writeStderr(s); writeStderr("?\n"); }
        },
        .ok => |parsed| dispatch(&parsed),
    }
}

fn dispatch(parsed: *const cli.ParsedArgs) void {
    const cmd = parsed.command orelse .help;
    if (cmd == .help) { printHelp(); return; }
    if (cmd == .version) { writeStdout("zpm v" ++ VERSION ++ "\n"); return; }

    // Select transport: QUIC or default HTTP stub
    var quic_vtable: registry.QuicTransportVtable = undefined;
    const use_quic = if (parsed.transport) |t| eqlStr(t, "quic") else false;
    const selected_http: registry.HttpVtable = if (use_quic) blk: {
        // QUIC transport: create connection + appmap, activate vtable
        // NOTE: Full QUIC connection setup (socket bind, handshake) would happen here.
        // For now, the vtable is wired but the caller must provide a live connection.
        // This path is a placeholder until the full QUIC client init is wired.
        writeStderr("quic transport: not yet fully wired (connection setup pending)\n");
        _ = &quic_vtable;
        break :blk http_vtable; // fall back until connection init is complete
    } else http_vtable;

    const reg = registry.RegistryClient{ .base_url = parsed.flags.registry_url orelse DEFAULT_REGISTRY, .offline = parsed.flags.offline, .http = selected_http };
    const boot = bootstrap.ZigBootstrapper{ .vtable = boot_vtable, .offline = parsed.flags.offline, .auto_update = parsed.yes };
    const ctx = commands.CommandContext{
        .registry_client = &reg, .stdout = &writeStdout, .stderr = &writeStderr,
        .read_file = &readFileCb, .write_file = &writeFileCb,
        .bootstrapper = &boot, .init_create_dir = &createDirCb, .init_write_file = &writeFileCb,
        .init_dir_exists = &dirExistsCb, .init_dir_is_empty = &dirIsEmptyCb,
        .init_remove_dir = &removeDirCb, .init_print = &writeStdout,
    };
    _ = switch (cmd) {
        .init => commands.initCmd(&ctx, parsed), .install => commands.install(&ctx, parsed),
        .uninstall => commands.uninstall(&ctx, parsed), .list => commands.listCmd(&ctx, parsed),
        .search => commands.searchCmd(&ctx, parsed), .publish => commands.publishCmd(&ctx, parsed),
        .validate => commands.validateCmd(&ctx, parsed), .update => commands.update(&ctx, parsed),
        .doctor => commands.doctorCmd(&ctx, parsed), .run => commands.runCmd(&ctx, parsed),
        .build => commands.buildCmd(&ctx, parsed), .help, .version => unreachable,
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
    writeStdout("zpm v" ++ VERSION ++ " — package manager for the zpm ecosystem\n\nUsage: zpm <command> [options] [args]\n\nCommands:\n  init            Scaffold a new project\n  install (i)     Install packages\n  uninstall (rm)  Remove packages\n  list (ls)       List installed packages\n  search          Search the registry\n  publish (pub)   Publish a package\n  validate (val)  Validate for publishing\n  update (up)     Update packages\n  doctor          Check environment health\n  run             Build and run\n  build           Build project\n\nFlags:\n  -v  --verbose   Detailed output\n  -q  --quiet     Suppress non-error output\n  --offline       No network requests\n  --registry URL  Override registry URL\n  -h  --help      Show help\n  -V  --version   Show version\n");
}
