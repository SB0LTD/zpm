// Platform Abstraction Layer — comptime OS dispatch for all I/O.
//
// Uses @import("builtin").os.tag to select Windows (Win32) or POSIX
// backends at comptime. All functions use stack buffers only — no heap.
//
// Requirements: 1.1, 1.4, 1.5, 1.6, 1.7, 1.8, 1.9

const builtin = @import("builtin");
const os_tag = builtin.os.tag;

pub const FileError = error{ NotFound, PermissionDenied, IoError };

pub const FileStat = struct {
    size: u64,
    is_dir: bool,
};

pub const ExecResult = struct {
    exit_code: u8,
    stdout: []const u8,
};

pub const HttpResult = union(enum) {
    ok: []const u8,
    err: HttpError,
};

pub const HttpError = error{
    ConnectionFailed,
    Timeout,
    InvalidUrl,
    BufferTooSmall,
};

// ── File I/O ──
pub fn readFile(path: []const u8, buf: []u8) FileError![]const u8 {
    if (os_tag == .windows) {
        return windowsReadFile(path, buf);
    } else {
        return posixReadFile(path, buf);
    }
}

pub fn writeFile(path: []const u8, data: []const u8) FileError!void {
    if (os_tag == .windows) {
        return windowsWriteFile(path, data);
    } else {
        return posixWriteFile(path, data);
    }
}

pub fn createDir(path: []const u8) FileError!void {
    if (os_tag == .windows) {
        return windowsCreateDir(path);
    } else {
        return posixCreateDir(path);
    }
}

pub fn removeDir(path: []const u8) FileError!void {
    if (os_tag == .windows) {
        return windowsRemoveDir(path);
    } else {
        return posixRemoveDir(path);
    }
}

pub fn stat(path: []const u8) FileError!FileStat {
    if (os_tag == .windows) {
        return windowsStat(path);
    } else {
        return posixStat(path);
    }
}

pub fn dirExists(path: []const u8) bool {
    if (os_tag == .windows) {
        return windowsDirExists(path);
    } else {
        return posixDirExists(path);
    }
}

pub fn dirIsEmpty(path: []const u8) bool {
    if (os_tag == .windows) {
        return windowsDirIsEmpty(path);
    } else {
        return posixDirIsEmpty(path);
    }
}

// ── Console I/O ──

pub fn writeStdout(data: []const u8) void {
    if (os_tag == .windows) {
        windowsWriteStdout(data);
    } else {
        posixWriteStdout(data);
    }
}

pub fn writeStderr(data: []const u8) void {
    if (os_tag == .windows) {
        windowsWriteStderr(data);
    } else {
        posixWriteStderr(data);
    }
}

// ── Process Execution ──

pub fn exec(cmd: []const u8, stdout_buf: []u8) ?ExecResult {
    if (os_tag == .windows) {
        return windowsExec(cmd, stdout_buf);
    } else {
        return posixExec(cmd, stdout_buf);
    }
}

// ── HTTP Client ──

pub fn httpGet(url: []const u8, response_buf: []u8) HttpResult {
    if (os_tag == .windows) {
        return windowsHttpGet(url, response_buf);
    } else {
        return posixHttpGet(url, response_buf);
    }
}

pub fn httpPost(url: []const u8, body: []const u8, response_buf: []u8) HttpResult {
    if (os_tag == .windows) {
        return windowsHttpPost(url, body, response_buf);
    } else {
        return posixHttpPost(url, body, response_buf);
    }
}

// ── Timer ──

pub fn timestamp() u64 {
    if (os_tag == .windows) {
        return windowsTimestamp();
    } else {
        return posixTimestamp();
    }
}
// ════════════════════════════════════════════════════════════════════
// Windows Backend (Win32 API)
// ════════════════════════════════════════════════════════════════════

const HANDLE = *opaque {};
const DWORD = u32;
const BOOL = c_int;
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

const win32 = if (os_tag == .windows) struct {
    extern "kernel32" fn GetStdHandle(DWORD) callconv(.c) HANDLE;
    extern "kernel32" fn WriteFile(HANDLE, [*]const u8, DWORD, ?*DWORD, ?*anyopaque) callconv(.c) BOOL;
    extern "kernel32" fn CreateFileA([*:0]const u8, DWORD, DWORD, ?*anyopaque, DWORD, DWORD, ?HANDLE) callconv(.c) HANDLE;
    extern "kernel32" fn ReadFile(HANDLE, [*]u8, DWORD, *DWORD, ?*anyopaque) callconv(.c) BOOL;
    extern "kernel32" fn CloseHandle(HANDLE) callconv(.c) BOOL;
    extern "kernel32" fn CreateDirectoryA([*:0]const u8, ?*anyopaque) callconv(.c) BOOL;
    extern "kernel32" fn GetFileAttributesA([*:0]const u8) callconv(.c) DWORD;
    extern "kernel32" fn RemoveDirectoryA([*:0]const u8) callconv(.c) BOOL;
    extern "kernel32" fn FindFirstFileA([*:0]const u8, *WIN32_FIND_DATAA) callconv(.c) HANDLE;
    extern "kernel32" fn FindNextFileA(HANDLE, *WIN32_FIND_DATAA) callconv(.c) BOOL;
    extern "kernel32" fn FindClose(HANDLE) callconv(.c) BOOL;
    extern "kernel32" fn CreateProcessA(?[*:0]const u8, ?[*:0]u8, ?*anyopaque, ?*anyopaque, BOOL, DWORD, ?*anyopaque, ?*anyopaque, *STARTUPINFOA, *PROCESS_INFORMATION) callconv(.c) BOOL;
    extern "kernel32" fn WaitForSingleObject(HANDLE, DWORD) callconv(.c) DWORD;
    extern "kernel32" fn GetExitCodeProcess(HANDLE, *DWORD) callconv(.c) BOOL;
    extern "kernel32" fn CreatePipe(*HANDLE, *HANDLE, ?*SECURITY_ATTRIBUTES, DWORD) callconv(.c) BOOL;
    extern "kernel32" fn QueryPerformanceCounter(*LARGE_INTEGER) callconv(.c) BOOL;
    extern "kernel32" fn QueryPerformanceFrequency(*LARGE_INTEGER) callconv(.c) BOOL;
    extern "kernel32" fn GetFileSizeEx(HANDLE, *LARGE_INTEGER) callconv(.c) BOOL;

    const WIN32_FIND_DATAA = extern struct {
        dwFileAttributes: DWORD,
        ftCreationTime: [8]u8,
        ftLastAccessTime: [8]u8,
        ftLastWriteTime: [8]u8,
        nFileSizeHigh: DWORD,
        nFileSizeLow: DWORD,
        dwReserved0: DWORD,
        dwReserved1: DWORD,
        cFileName: [260]u8,
        cAlternateFileName: [14]u8,
    };

    const STARTUPINFOA = extern struct {
        cb: DWORD = @sizeOf(STARTUPINFOA),
        lpReserved: ?*anyopaque = null,
        lpDesktop: ?*anyopaque = null,
        lpTitle: ?*anyopaque = null,
        dwX: DWORD = 0,
        dwY: DWORD = 0,
        dwXSize: DWORD = 0,
        dwYSize: DWORD = 0,
        dwXCountChars: DWORD = 0,
        dwYCountChars: DWORD = 0,
        dwFillAttribute: DWORD = 0,
        dwFlags: DWORD = 0,
        wShowWindow: u16 = 0,
        cbReserved2: u16 = 0,
        lpReserved2: ?*anyopaque = null,
        hStdInput: ?HANDLE = null,
        hStdOutput: ?HANDLE = null,
        hStdError: ?HANDLE = null,
    };

    const PROCESS_INFORMATION = extern struct {
        hProcess: HANDLE = undefined,
        hThread: HANDLE = undefined,
        dwProcessId: DWORD = 0,
        dwThreadId: DWORD = 0,
    };

    const SECURITY_ATTRIBUTES = extern struct {
        nLength: DWORD = @sizeOf(SECURITY_ATTRIBUTES),
        lpSecurityDescriptor: ?*anyopaque = null,
        bInheritHandle: BOOL = 1,
    };

    const LARGE_INTEGER = extern struct {
        QuadPart: i64 = 0,
    };
} else struct {};
fn toZ(path: []const u8, buf: *[512]u8) ?[*:0]const u8 {
    if (path.len >= 512) return null;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    return @ptrCast(buf[0..path.len :0]);
}

fn windowsReadFile(path: []const u8, buf: []u8) FileError![]const u8 {
    var z: [512]u8 = undefined;
    const p = toZ(path, &z) orelse return error.IoError;
    const h = win32.CreateFileA(p, GENERIC_READ, FILE_SHARE_READ, null, OPEN_EXISTING, 0, null);
    if (h == INVALID_HANDLE_VALUE) return error.NotFound;
    defer _ = win32.CloseHandle(h);
    var n: DWORD = 0;
    if (win32.ReadFile(h, buf.ptr, @intCast(buf.len), &n, null) == 0) return error.IoError;
    return buf[0..n];
}

fn windowsWriteFile(path: []const u8, data: []const u8) FileError!void {
    var z: [512]u8 = undefined;
    const p = toZ(path, &z) orelse return error.IoError;
    const h = win32.CreateFileA(p, GENERIC_WRITE, 0, null, CREATE_ALWAYS, 0, null);
    if (h == INVALID_HANDLE_VALUE) return error.PermissionDenied;
    defer _ = win32.CloseHandle(h);
    _ = win32.WriteFile(h, data.ptr, @intCast(data.len), null, null);
}

fn windowsCreateDir(path: []const u8) FileError!void {
    var z: [512]u8 = undefined;
    const p = toZ(path, &z) orelse return error.IoError;
    if (win32.CreateDirectoryA(p, null) == 0) return error.PermissionDenied;
}

fn windowsRemoveDir(path: []const u8) FileError!void {
    var z: [512]u8 = undefined;
    const p = toZ(path, &z) orelse return error.IoError;
    if (win32.RemoveDirectoryA(p) == 0) return error.PermissionDenied;
}

fn windowsStat(path: []const u8) FileError!FileStat {
    var z: [512]u8 = undefined;
    const p = toZ(path, &z) orelse return error.IoError;
    const attrs = win32.GetFileAttributesA(p);
    if (attrs == INVALID_FILE_ATTRIBUTES) return error.NotFound;
    const is_dir = (attrs & FILE_ATTRIBUTE_DIRECTORY) != 0;
    // Get file size via CreateFileA + GetFileSizeEx
    if (!is_dir) {
        const h = win32.CreateFileA(p, GENERIC_READ, FILE_SHARE_READ, null, OPEN_EXISTING, 0, null);
        if (h != INVALID_HANDLE_VALUE) {
            defer _ = win32.CloseHandle(h);
            var li: win32.LARGE_INTEGER = .{};
            if (win32.GetFileSizeEx(h, &li) != 0) {
                return .{ .size = @intCast(li.QuadPart), .is_dir = false };
            }
        }
    }
    return .{ .size = 0, .is_dir = is_dir };
}

fn windowsDirExists(path: []const u8) bool {
    var z: [512]u8 = undefined;
    const p = toZ(path, &z) orelse return false;
    const a = win32.GetFileAttributesA(p);
    return a != INVALID_FILE_ATTRIBUTES and (a & FILE_ATTRIBUTE_DIRECTORY) != 0;
}

fn windowsDirIsEmpty(path: []const u8) bool {
    // Build search pattern: path\*
    var search_buf: [516]u8 = undefined;
    if (path.len + 2 >= search_buf.len) return true;
    @memcpy(search_buf[0..path.len], path);
    search_buf[path.len] = '\\';
    search_buf[path.len + 1] = '*';
    search_buf[path.len + 2] = 0;
    var find_data: win32.WIN32_FIND_DATAA = undefined;
    const h = win32.FindFirstFileA(@ptrCast(search_buf[0 .. path.len + 2 :0]), &find_data);
    if (h == INVALID_HANDLE_VALUE) return true;
    defer _ = win32.FindClose(h);
    // Skip . and .. entries
    var count: usize = 0;
    while (true) {
        const name_slice = nameFromFindData(&find_data);
        if (!isDotDir(name_slice)) count += 1;
        if (count > 0) return false;
        if (win32.FindNextFileA(h, &find_data) == 0) break;
    }
    return count == 0;
}

fn nameFromFindData(fd: *const win32.WIN32_FIND_DATAA) []const u8 {
    var len: usize = 0;
    while (len < fd.cFileName.len and fd.cFileName[len] != 0) : (len += 1) {}
    return fd.cFileName[0..len];
}

fn isDotDir(name: []const u8) bool {
    if (name.len == 1 and name[0] == '.') return true;
    if (name.len == 2 and name[0] == '.' and name[1] == '.') return true;
    return false;
}

fn windowsWriteStdout(data: []const u8) void {
    _ = win32.WriteFile(win32.GetStdHandle(STD_OUTPUT_HANDLE), data.ptr, @intCast(data.len), null, null);
}

fn windowsWriteStderr(data: []const u8) void {
    _ = win32.WriteFile(win32.GetStdHandle(STD_ERROR_HANDLE), data.ptr, @intCast(data.len), null, null);
}

fn windowsExec(cmd: []const u8, stdout_buf: []u8) ?ExecResult {
    // Create pipe for stdout capture
    var sa: win32.SECURITY_ATTRIBUTES = .{};
    var read_pipe: HANDLE = undefined;
    var write_pipe: HANDLE = undefined;
    if (win32.CreatePipe(&read_pipe, &write_pipe, &sa, 0) == 0) return null;

    var si: win32.STARTUPINFOA = .{};
    si.dwFlags = 0x00000100; // STARTF_USESTDHANDLES
    si.hStdOutput = write_pipe;
    si.hStdError = write_pipe;

    var pi: win32.PROCESS_INFORMATION = .{};

    // Copy cmd to mutable null-terminated buffer
    var cmd_buf: [1024]u8 = undefined;
    if (cmd.len >= cmd_buf.len) return null;
    @memcpy(cmd_buf[0..cmd.len], cmd);
    cmd_buf[cmd.len] = 0;

    if (win32.CreateProcessA(null, @ptrCast(cmd_buf[0..cmd.len :0]), null, null, 1, 0, null, null, &si, &pi) == 0) {
        _ = win32.CloseHandle(read_pipe);
        _ = win32.CloseHandle(write_pipe);
        return null;
    }

    _ = win32.CloseHandle(write_pipe);
    _ = win32.WaitForSingleObject(pi.hProcess, 0xFFFFFFFF); // INFINITE

    // Read stdout
    var total: usize = 0;
    while (total < stdout_buf.len) {
        var n: DWORD = 0;
        if (win32.ReadFile(read_pipe, stdout_buf[total..].ptr, @intCast(stdout_buf.len - total), &n, null) == 0) break;
        if (n == 0) break;
        total += n;
    }

    var exit_code: DWORD = 0;
    _ = win32.GetExitCodeProcess(pi.hProcess, &exit_code);

    _ = win32.CloseHandle(read_pipe);
    _ = win32.CloseHandle(pi.hProcess);
    _ = win32.CloseHandle(pi.hThread);

    return .{ .exit_code = @truncate(exit_code), .stdout = stdout_buf[0..total] };
}

fn windowsHttpGet(_: []const u8, _: []u8) HttpResult {
    // WinHTTP stub — full implementation requires WinHTTP API wiring
    return .{ .err = error.ConnectionFailed };
}

fn windowsHttpPost(_: []const u8, _: []const u8, _: []u8) HttpResult {
    return .{ .err = error.ConnectionFailed };
}

fn windowsTimestamp() u64 {
    var freq: win32.LARGE_INTEGER = .{};
    var counter: win32.LARGE_INTEGER = .{};
    _ = win32.QueryPerformanceFrequency(&freq);
    _ = win32.QueryPerformanceCounter(&counter);
    const f: u64 = if (freq.QuadPart > 0) @intCast(freq.QuadPart) else 1;
    const c: u64 = if (counter.QuadPart > 0) @intCast(counter.QuadPart) else 0;
    // Convert to nanoseconds: (counter * 1_000_000_000) / freq
    return (c * 1_000_000_000) / f;
}
// ════════════════════════════════════════════════════════════════════
// POSIX Backend (Linux / macOS)
// ════════════════════════════════════════════════════════════════════

const posix = if (os_tag != .windows) struct {
    const O_RDONLY: c_int = 0;
    const O_WRONLY: c_int = 1;
    const O_CREAT: c_int = if (os_tag == .macos) 0x200 else 0x40;
    const O_TRUNC: c_int = if (os_tag == .macos) 0x400 else 0x200;
    const S_IRWXU: c_uint = 0o700;
    const S_IRUSR: c_uint = 0o400;
    const S_IWUSR: c_uint = 0o200;
    const S_IRGRP: c_uint = 0o040;
    const S_IROTH: c_uint = 0o004;
    const AT_FDCWD: c_int = if (os_tag == .macos) -2 else -100;
    const CLOCK_MONOTONIC: c_int = if (os_tag == .macos) 6 else 1;

    const Stat = if (os_tag == .macos) extern struct {
        st_dev: i32,
        st_mode: u16,
        st_nlink: u16,
        st_ino: u64,
        st_uid: u32,
        st_gid: u32,
        st_rdev: i32,
        st_atimespec: Timespec,
        st_mtimespec: Timespec,
        st_ctimespec: Timespec,
        st_birthtimespec: Timespec,
        st_size: i64,
        st_blocks: i64,
        st_blksize: i32,
        st_flags: u32,
        st_gen: u32,
        st_lspare: i32,
        st_qspare: [2]i64,
    } else extern struct {
        st_dev: u64,
        st_ino: u64,
        st_nlink: u64,
        st_mode: u32,
        st_uid: u32,
        st_gid: u32,
        __pad0: u32,
        st_rdev: u64,
        st_size: i64,
        st_blksize: i64,
        st_blocks: i64,
        st_atim: Timespec,
        st_mtim: Timespec,
        st_ctim: Timespec,
        __unused: [3]i64,
    };

    const Timespec = extern struct {
        tv_sec: i64,
        tv_nsec: i64,
    };

    const S_IFMT: u32 = 0o170000;
    const S_IFDIR: u32 = 0o040000;

    const Dirent = if (os_tag == .macos) extern struct {
        d_ino: u64,
        d_seekoff: u64,
        d_reclen: u16,
        d_namlen: u16,
        d_type: u8,
        d_name: [1024]u8,
    } else extern struct {
        d_ino: u64,
        d_off: i64,
        d_reclen: u16,
        d_type: u8,
        d_name: [256]u8,
    };

    const DIR = opaque {};

    extern "c" fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
    extern "c" fn read(fd: c_int, buf: [*]u8, count: usize) isize;
    extern "c" fn write(fd: c_int, buf: [*]const u8, count: usize) isize;
    extern "c" fn close(fd: c_int) c_int;
    extern "c" fn mkdir(path: [*:0]const u8, mode: c_uint) c_int;
    extern "c" fn rmdir(path: [*:0]const u8) c_int;
    extern "c" fn opendir(path: [*:0]const u8) ?*DIR;
    extern "c" fn readdir(dir: *DIR) ?*Dirent;
    extern "c" fn closedir(dir: *DIR) c_int;
    extern "c" fn clock_gettime(clk_id: c_int, tp: *Timespec) c_int;

    // Use fstatat for stat (works on both Linux and macOS)
    extern "c" fn fstatat(dirfd: c_int, path: [*:0]const u8, buf: *Stat, flags: c_int) c_int;

    // posix_spawn for process execution
    const PosixSpawnFileActions = opaque {};
    const PosixSpawnAttr = opaque {};
    extern "c" fn posix_spawn(pid: *c_int, path: [*:0]const u8, file_actions: ?*const PosixSpawnFileActions, attrp: ?*const PosixSpawnAttr, argv: [*:null]const ?[*:0]const u8, envp: [*:null]const ?[*:0]const u8) c_int;
    extern "c" fn waitpid(pid: c_int, status: *c_int, options: c_int) c_int;
    extern "c" fn pipe(pipefd: *[2]c_int) c_int;
    extern "c" fn dup2(oldfd: c_int, newfd: c_int) c_int;
    extern "c" fn fork() c_int;
    extern "c" fn execl(path: [*:0]const u8, arg0: [*:0]const u8, ...) c_int;
    extern "c" fn _exit(status: c_int) noreturn;
} else struct {};

fn posixToZ(path: []const u8, buf: *[512]u8) ?[*:0]const u8 {
    if (path.len >= 512) return null;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    return @ptrCast(buf[0..path.len :0]);
}

fn posixReadFile(path: []const u8, buf: []u8) FileError![]const u8 {
    var z: [512]u8 = undefined;
    const p = posixToZ(path, &z) orelse return error.IoError;
    const fd = posix.open(p, posix.O_RDONLY);
    if (fd < 0) return error.NotFound;
    defer _ = posix.close(fd);
    var total: usize = 0;
    while (total < buf.len) {
        const n = posix.read(fd, buf[total..].ptr, buf.len - total);
        if (n <= 0) break;
        total += @intCast(n);
    }
    return buf[0..total];
}

fn posixWriteFile(path: []const u8, data: []const u8) FileError!void {
    var z: [512]u8 = undefined;
    const p = posixToZ(path, &z) orelse return error.IoError;
    const fd = posix.open(p, posix.O_WRONLY | posix.O_CREAT | posix.O_TRUNC, posix.S_IRUSR | posix.S_IWUSR | posix.S_IRGRP | posix.S_IROTH);
    if (fd < 0) return error.PermissionDenied;
    defer _ = posix.close(fd);
    var written: usize = 0;
    while (written < data.len) {
        const n = posix.write(fd, data[written..].ptr, data.len - written);
        if (n <= 0) return error.IoError;
        written += @intCast(n);
    }
}

fn posixCreateDir(path: []const u8) FileError!void {
    var z: [512]u8 = undefined;
    const p = posixToZ(path, &z) orelse return error.IoError;
    if (posix.mkdir(p, posix.S_IRWXU) != 0) return error.PermissionDenied;
}

fn posixRemoveDir(path: []const u8) FileError!void {
    var z: [512]u8 = undefined;
    const p = posixToZ(path, &z) orelse return error.IoError;
    if (posix.rmdir(p) != 0) return error.PermissionDenied;
}

fn posixStat(path: []const u8) FileError!FileStat {
    var z: [512]u8 = undefined;
    const p = posixToZ(path, &z) orelse return error.IoError;
    var st: posix.Stat = undefined;
    if (posix.fstatat(posix.AT_FDCWD, p, &st, 0) != 0) return error.NotFound;
    const mode: u32 = if (os_tag == .macos) @as(u32, st.st_mode) else st.st_mode;
    return .{
        .size = if (st.st_size > 0) @intCast(st.st_size) else 0,
        .is_dir = (mode & posix.S_IFMT) == posix.S_IFDIR,
    };
}

fn posixDirExists(path: []const u8) bool {
    const s = posixStat(path) catch return false;
    return s.is_dir;
}

fn posixDirIsEmpty(path: []const u8) bool {
    var z: [512]u8 = undefined;
    const p = posixToZ(path, &z) orelse return true;
    const dir = posix.opendir(p) orelse return true;
    defer _ = posix.closedir(dir);
    while (posix.readdir(dir)) |entry| {
        const name = direntName(entry);
        if (name.len == 1 and name[0] == '.') continue;
        if (name.len == 2 and name[0] == '.' and name[1] == '.') continue;
        return false;
    }
    return true;
}

fn direntName(entry: *const posix.Dirent) []const u8 {
    var len: usize = 0;
    while (len < entry.d_name.len and entry.d_name[len] != 0) : (len += 1) {}
    return entry.d_name[0..len];
}

fn posixWriteStdout(data: []const u8) void {
    _ = posix.write(1, data.ptr, data.len);
}

fn posixWriteStderr(data: []const u8) void {
    _ = posix.write(2, data.ptr, data.len);
}

fn posixExec(cmd: []const u8, stdout_buf: []u8) ?ExecResult {
    // Use fork + exec with pipe for stdout capture
    var pipefd: [2]c_int = undefined;
    if (posix.pipe(&pipefd) != 0) return null;

    const pid = posix.fork();
    if (pid < 0) {
        _ = posix.close(pipefd[0]);
        _ = posix.close(pipefd[1]);
        return null;
    }

    if (pid == 0) {
        // Child: redirect stdout to pipe write end
        _ = posix.close(pipefd[0]);
        _ = posix.dup2(pipefd[1], 1);
        _ = posix.dup2(pipefd[1], 2);
        _ = posix.close(pipefd[1]);

        // Build null-terminated cmd
        var cmd_z: [1024]u8 = undefined;
        if (cmd.len >= cmd_z.len) posix._exit(127);
        @memcpy(cmd_z[0..cmd.len], cmd);
        cmd_z[cmd.len] = 0;

        const sh: [*:0]const u8 = "/bin/sh";
        const c_flag: [*:0]const u8 = "-c";
        const argv = [_:null]?[*:0]const u8{ sh, c_flag, @ptrCast(cmd_z[0..cmd.len :0]), null };
        const envp = [_:null]?[*:0]const u8{null};
        _ = posix.execl(sh, sh, c_flag, @as([*:0]const u8, @ptrCast(cmd_z[0..cmd.len :0])), @as(?[*:0]const u8, null));
        _ = argv;
        _ = envp;
        posix._exit(127);
    }

    // Parent: read from pipe
    _ = posix.close(pipefd[1]);
    var total: usize = 0;
    while (total < stdout_buf.len) {
        const n = posix.read(pipefd[0], stdout_buf[total..].ptr, stdout_buf.len - total);
        if (n <= 0) break;
        total += @intCast(n);
    }
    _ = posix.close(pipefd[0]);

    var status: c_int = 0;
    _ = posix.waitpid(pid, &status, 0);
    const exit_code: u8 = @truncate(@as(u32, @bitCast(status)) >> 8);

    return .{ .exit_code = exit_code, .stdout = stdout_buf[0..total] };
}

fn posixHttpGet(_: []const u8, _: []u8) HttpResult {
    // HTTP stub for non-Windows — full implementation would use raw sockets or libcurl
    return .{ .err = error.ConnectionFailed };
}

fn posixHttpPost(_: []const u8, _: []const u8, _: []u8) HttpResult {
    return .{ .err = error.ConnectionFailed };
}

fn posixTimestamp() u64 {
    var ts: posix.Timespec = .{ .tv_sec = 0, .tv_nsec = 0 };
    _ = posix.clock_gettime(posix.CLOCK_MONOTONIC, &ts);
    return @as(u64, @intCast(ts.tv_sec)) * 1_000_000_000 + @as(u64, @intCast(ts.tv_nsec));
}

// ── Vtable Adapters ──
// These adapt PAL functions to the callback signatures used by CommandContext.

pub fn palReadFileCb(path: []const u8, buf: []u8) ?[]const u8 {
    return readFile(path, buf) catch null;
}

pub fn palWriteFileCb(path: []const u8, data: []const u8) bool {
    writeFile(path, data) catch return false;
    return true;
}

pub fn palCreateDirCb(path: []const u8) bool {
    createDir(path) catch return false;
    return true;
}

pub fn palDirExistsCb(path: []const u8) bool {
    return dirExists(path);
}

pub fn palDirIsEmptyCb(path: []const u8) bool {
    return dirIsEmpty(path);
}

pub fn palRemoveDirCb(path: []const u8) bool {
    removeDir(path) catch return false;
    return true;
}
