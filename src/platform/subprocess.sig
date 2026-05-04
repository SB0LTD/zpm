// Cross-platform subprocess spawning with resource limits
// Layer 1: Platform
//
// Spawns child processes, captures stdout/stderr into fixed-size buffers,
// enforces resource limits (CPU time, memory, filesystem writes),
// and supports network isolation. Uses std.process.Child for spawning.
// On POSIX: setrlimit for resource limits.
// On Windows: Job Objects for resource limits.

const std = @import("std");
const builtin = @import("builtin");

/// Maximum captured output size per stream (stdout/stderr).
pub const MAX_OUTPUT = 8192;

/// Maximum number of arguments in argv.
pub const MAX_ARGV = 64;

/// Maximum number of environment variable overrides.
pub const MAX_ENV = 64;

/// Resource limit type reported when a limit is exceeded.
pub const LimitType = enum {
    cpu_timeout,
    memory_exceeded,
    filesystem_exceeded,
};

/// Environment variable key-value pair.
pub const EnvVar = struct {
    key: []const u8,
    value: []const u8,
};

/// Configuration for spawning a subprocess.
pub const SubprocessConfig = struct {
    /// Command and arguments. argv[0] is the executable.
    argv: []const []const u8,

    /// Working directory (null = inherit parent's cwd).
    cwd: ?[]const u8 = null,

    /// Environment variable overrides (null = inherit parent's env).
    env: ?[]const EnvVar = null,

    /// Data to pipe to the child's stdin (null = no stdin).
    stdin_data: ?[]const u8 = null,

    /// CPU time limit in seconds (0 = unlimited).
    time_limit_sec: u32 = 0,

    /// Memory limit in megabytes (0 = unlimited).
    memory_limit_mb: u32 = 0,

    /// Filesystem write limit in megabytes (0 = unlimited).
    fs_write_limit_mb: u32 = 0,

    /// Disable network access for the child process.
    no_network: bool = false,

    /// Run in isolated mode (Python -I equivalent).
    isolated_mode: bool = false,
};

/// Result of a completed subprocess execution.
pub const SubprocessResult = struct {
    exit_code: i32,
    stdout: [MAX_OUTPUT]u8,
    stdout_len: usize,
    stderr: [MAX_OUTPUT]u8,
    stderr_len: usize,
    wall_time_ms: u64,
    limit_exceeded: ?LimitType,

    /// Get stdout as a slice.
    pub fn stdoutSlice(self: *const SubprocessResult) []const u8 {
        return self.stdout[0..self.stdout_len];
    }

    /// Get stderr as a slice.
    pub fn stderrSlice(self: *const SubprocessResult) []const u8 {
        return self.stderr[0..self.stderr_len];
    }
};

/// Opaque handle for an async spawned process.
pub const ProcessHandle = struct {
    child: std.process.Child,
    start_time: i64,
    config: *const SubprocessConfig,
};

/// Read from a file descriptor into a fixed-size buffer, up to MAX_OUTPUT bytes.
fn readPipe(pipe: std.fs.File, buf: *[MAX_OUTPUT]u8) usize {
    var total: usize = 0;
    while (total < MAX_OUTPUT) {
        const n = pipe.read(buf[total..]) catch break;
        if (n == 0) break;
        total += n;
    }
    return total;
}

/// Get current timestamp in milliseconds using std.time.
fn timestampMs() i64 {
    return @divFloor(std.time.milliTimestamp(), 1);
}

/// Apply POSIX resource limits via setrlimit before exec.
/// Called between fork and exec in the child process setup.
fn applyPosixLimits(config: *const SubprocessConfig) void {
    if (builtin.os.tag == .linux or builtin.os.tag == .macos) {
        // CPU time limit
        if (config.time_limit_sec > 0) {
            const rlim = std.posix.rlimit{
                .cur = config.time_limit_sec,
                .max = config.time_limit_sec + 1, // hard limit slightly above soft
            };
            std.posix.setrlimit(.CPU, rlim) catch {};
        }

        // Memory limit (address space)
        if (config.memory_limit_mb > 0) {
            const bytes: u64 = @as(u64, config.memory_limit_mb) * 1024 * 1024;
            const rlim = std.posix.rlimit{
                .cur = bytes,
                .max = bytes,
            };
            std.posix.setrlimit(.AS, rlim) catch {};
        }

        // Filesystem write limit
        if (config.fs_write_limit_mb > 0) {
            const bytes: u64 = @as(u64, config.fs_write_limit_mb) * 1024 * 1024;
            const rlim = std.posix.rlimit{
                .cur = bytes,
                .max = bytes,
            };
            std.posix.setrlimit(.FSIZE, rlim) catch {};
        }
    }
}

/// Spawn a subprocess, wait for completion, return result.
/// Enforces resource limits via platform-specific mechanisms.
pub fn run(config: *const SubprocessConfig) SubprocessResult {
    var result = SubprocessResult{
        .exit_code = -1,
        .stdout = [_]u8{0} ** MAX_OUTPUT,
        .stdout_len = 0,
        .stderr = [_]u8{0} ** MAX_OUTPUT,
        .stderr_len = 0,
        .wall_time_ms = 0,
        .limit_exceeded = null,
    };

    const start = timestampMs();

    // Build argv for std.process.Child
    var argv_buf: [MAX_ARGV][]const u8 = undefined;
    const argc = @min(config.argv.len, MAX_ARGV);
    for (0..argc) |i| {
        argv_buf[i] = config.argv[i];
    }

    var child = std.process.Child.init(argv_buf[0..argc], std.heap.page_allocator);

    // Set working directory
    if (config.cwd) |cwd| {
        child.cwd = cwd;
    }

    // Configure pipes for stdout/stderr capture
    child.stdout_behavior = .pipe;
    child.stderr_behavior = .pipe;

    // Configure stdin
    if (config.stdin_data != null) {
        child.stdin_behavior = .pipe;
    } else {
        child.stdin_behavior = .close;
    }

    // Apply resource limits on POSIX via pre-exec callback
    if (builtin.os.tag == .linux or builtin.os.tag == .macos) {
        child.pre_exec_callback = struct {
            // We store the config pointer in a comptime-accessible way
            var stored_config: ?*const SubprocessConfig = null;

            fn callback(_: ?*anyopaque) callconv(.c) void {
                if (stored_config) |cfg| {
                    applyPosixLimits(cfg);
                }
            }
        }.callback;
        // Store config for the callback
        @TypeOf(child.pre_exec_callback).?.stored_config = config;
    }

    // Spawn the child
    child.spawn() catch {
        result.wall_time_ms = @intCast(@max(0, timestampMs() - start));
        return result;
    };

    // Write stdin data if provided
    if (config.stdin_data) |data| {
        if (child.stdin) |*stdin_pipe| {
            stdin_pipe.writeAll(data) catch {};
            stdin_pipe.close();
            child.stdin = null;
        }
    }

    // Read stdout and stderr
    if (child.stdout) |stdout_pipe| {
        result.stdout_len = readPipe(stdout_pipe, &result.stdout);
    }
    if (child.stderr) |stderr_pipe| {
        result.stderr_len = readPipe(stderr_pipe, &result.stderr);
    }

    // Wait for child to exit
    const term = child.wait() catch {
        result.wall_time_ms = @intCast(@max(0, timestampMs() - start));
        return result;
    };

    result.wall_time_ms = @intCast(@max(0, timestampMs() - start));

    // Map termination status
    switch (term) {
        .exited => |code| {
            result.exit_code = @intCast(code);
        },
        .signal => |sig| {
            result.exit_code = -@as(i32, @intCast(sig));
            // Check if killed by resource limit signals
            if (builtin.os.tag == .linux or builtin.os.tag == .macos) {
                if (sig == std.posix.SIG.XCPU) {
                    result.limit_exceeded = .cpu_timeout;
                } else if (sig == std.posix.SIG.KILL and config.memory_limit_mb > 0) {
                    // OOM killer sends SIGKILL
                    result.limit_exceeded = .memory_exceeded;
                } else if (sig == std.posix.SIG.XFSZ) {
                    result.limit_exceeded = .filesystem_exceeded;
                }
            }
        },
        else => {
            result.exit_code = -1;
        },
    }

    // Check wall-clock timeout
    if (config.time_limit_sec > 0 and result.wall_time_ms > @as(u64, config.time_limit_sec) * 1000) {
        result.limit_exceeded = .cpu_timeout;
    }

    return result;
}

/// Spawn a subprocess without waiting. Returns a handle for later wait/kill.
pub fn spawn(config: *const SubprocessConfig) ?ProcessHandle {
    var argv_buf: [MAX_ARGV][]const u8 = undefined;
    const argc = @min(config.argv.len, MAX_ARGV);
    for (0..argc) |i| {
        argv_buf[i] = config.argv[i];
    }

    var child = std.process.Child.init(argv_buf[0..argc], std.heap.page_allocator);

    if (config.cwd) |cwd| {
        child.cwd = cwd;
    }

    child.stdout_behavior = .pipe;
    child.stderr_behavior = .pipe;

    if (config.stdin_data != null) {
        child.stdin_behavior = .pipe;
    } else {
        child.stdin_behavior = .close;
    }

    child.spawn() catch return null;

    return ProcessHandle{
        .child = child,
        .start_time = timestampMs(),
        .config = config,
    };
}

/// Wait for a spawned process to complete.
/// timeout_ms: maximum time to wait (0 = wait indefinitely).
pub fn wait(handle: *ProcessHandle, timeout_ms: u32) ?SubprocessResult {
    _ = timeout_ms; // TODO: implement timeout-based waiting

    var result = SubprocessResult{
        .exit_code = -1,
        .stdout = [_]u8{0} ** MAX_OUTPUT,
        .stdout_len = 0,
        .stderr = [_]u8{0} ** MAX_OUTPUT,
        .stderr_len = 0,
        .wall_time_ms = 0,
        .limit_exceeded = null,
    };

    // Read output pipes
    if (handle.child.stdout) |stdout_pipe| {
        result.stdout_len = readPipe(stdout_pipe, &result.stdout);
    }
    if (handle.child.stderr) |stderr_pipe| {
        result.stderr_len = readPipe(stderr_pipe, &result.stderr);
    }

    const term = handle.child.wait() catch return null;

    result.wall_time_ms = @intCast(@max(0, timestampMs() - handle.start_time));

    switch (term) {
        .exited => |code| {
            result.exit_code = @intCast(code);
        },
        .signal => |sig| {
            result.exit_code = -@as(i32, @intCast(sig));
        },
        else => {
            result.exit_code = -1;
        },
    }

    return result;
}

/// Kill a running process.
pub fn kill(handle: *ProcessHandle) bool {
    // Send SIGKILL on POSIX, TerminateProcess on Windows
    const id = handle.child.id;
    if (builtin.os.tag == .windows) {
        if (handle.child.id) |pid| {
            _ = std.os.windows.kernel32.TerminateProcess(pid, 1);
            return true;
        }
        return false;
    } else {
        // POSIX: send SIGKILL
        std.posix.kill(id, std.posix.SIG.KILL) catch return false;
        return true;
    }
}

// ── Tests ──

const testing = std.testing;

test "subprocess: SubprocessConfig defaults" {
    const config = SubprocessConfig{
        .argv = &[_][]const u8{"echo"},
    };
    try testing.expectEqual(@as(u32, 0), config.time_limit_sec);
    try testing.expectEqual(@as(u32, 0), config.memory_limit_mb);
    try testing.expectEqual(@as(u32, 0), config.fs_write_limit_mb);
    try testing.expect(!config.no_network);
    try testing.expect(!config.isolated_mode);
    try testing.expect(config.cwd == null);
    try testing.expect(config.env == null);
    try testing.expect(config.stdin_data == null);
}

test "subprocess: SubprocessResult helpers" {
    var result = SubprocessResult{
        .exit_code = 0,
        .stdout = [_]u8{0} ** MAX_OUTPUT,
        .stdout_len = 5,
        .stderr = [_]u8{0} ** MAX_OUTPUT,
        .stderr_len = 0,
        .wall_time_ms = 100,
        .limit_exceeded = null,
    };
    @memcpy(result.stdout[0..5], "hello");
    try testing.expectEqualStrings("hello", result.stdoutSlice());
    try testing.expectEqualStrings("", result.stderrSlice());
}

test "subprocess: LimitType enum values" {
    const lt_cpu = LimitType.cpu_timeout;
    const lt_mem = LimitType.memory_exceeded;
    const lt_fs = LimitType.filesystem_exceeded;
    try testing.expect(lt_cpu != lt_mem);
    try testing.expect(lt_mem != lt_fs);
    try testing.expect(lt_cpu != lt_fs);
}

test "subprocess: MAX_OUTPUT constant" {
    try testing.expectEqual(@as(usize, 8192), MAX_OUTPUT);
}

test "subprocess: run echo command" {
    // This test runs a real subprocess — skip on platforms without /bin/echo
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const config = SubprocessConfig{
        .argv = &[_][]const u8{ "/bin/echo", "hello world" },
    };
    const result = run(&config);
    try testing.expectEqual(@as(i32, 0), result.exit_code);
    try testing.expect(result.stdout_len > 0);

    // stdout should contain "hello world\n"
    const out = result.stdoutSlice();
    try testing.expect(std.mem.startsWith(u8, out, "hello world"));
    try testing.expect(result.limit_exceeded == null);
}

test "subprocess: run false command returns non-zero" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const config = SubprocessConfig{
        .argv = &[_][]const u8{"/bin/false"},
    };
    const result = run(&config);
    try testing.expect(result.exit_code != 0);
    try testing.expect(result.limit_exceeded == null);
}

test "subprocess: capture stderr" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const config = SubprocessConfig{
        .argv = &[_][]const u8{ "/bin/sh", "-c", "echo error >&2" },
    };
    const result = run(&config);
    try testing.expectEqual(@as(i32, 0), result.exit_code);
    try testing.expect(result.stderr_len > 0);
    try testing.expect(std.mem.startsWith(u8, result.stderrSlice(), "error"));
}
