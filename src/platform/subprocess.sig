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
    policy_unavailable,
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
};

/// Read from a file descriptor into a fixed-size buffer, up to MAX_OUTPUT bytes.
fn readPipe(io: std.Io, pipe: std.Io.File, buf: *[MAX_OUTPUT]u8) usize {
    var reader_buffer: [4096]u8 = undefined;
    var reader = pipe.readerStreaming(io, &reader_buffer);
    var total: usize = 0;
    while (total < MAX_OUTPUT) {
        const n = reader.interface.readSliceShort(buf[total..]) catch break;
        if (n == 0) break;
        total += n;
    }
    return total;
}

/// Get current timestamp in milliseconds using std.time.
fn timestampMs(io: std.Io) i64 {
    return std.Io.Timestamp.now(io, .awake).toMilliseconds();
}

/// The generic std.Io process API cannot install pre-exec rlimits or a network
/// namespace. Reject such requests before spawn rather than silently running
/// with weaker isolation than the caller requested.
fn requiresUnavailablePolicy(config: *const SubprocessConfig) bool {
    return config.env != null or config.time_limit_sec != 0 or config.memory_limit_mb != 0 or
        config.fs_write_limit_mb != 0 or config.no_network or config.isolated_mode;
}

/// Spawn a subprocess, wait for completion, return result.
/// Unsupported isolation policies fail closed with `.policy_unavailable`.
pub fn run(io: std.Io, config: *const SubprocessConfig) SubprocessResult {
    var result = SubprocessResult{
        .exit_code = -1,
        .stdout = @as([MAX_OUTPUT]u8, @splat(0)),
        .stdout_len = 0,
        .stderr = @as([MAX_OUTPUT]u8, @splat(0)),
        .stderr_len = 0,
        .wall_time_ms = 0,
        .limit_exceeded = null,
    };

    const start = timestampMs(io);

    if (requiresUnavailablePolicy(config)) {
        result.limit_exceeded = .policy_unavailable;
        return result;
    }

    // Build argv for std.process.Child
    var argv_buf: [MAX_ARGV][]const u8 = undefined;
    const argc = @min(config.argv.len, MAX_ARGV);
    for (0..argc) |i| {
        argv_buf[i] = config.argv[i];
    }

    var child = std.process.spawn(io, .{
        .argv = argv_buf[0..argc],
        .cwd = if (config.cwd) |cwd| .{ .path = cwd } else .inherit,
        .stdin = if (config.stdin_data != null) .pipe else .close,
        .stdout = .pipe,
        .stderr = .pipe,
        .request_resource_usage_statistics = true,
    }) catch {
        result.wall_time_ms = @intCast(@max(0, timestampMs(io) - start));
        return result;
    };
    defer child.kill(io);

    // Write stdin data if provided
    if (config.stdin_data) |data| {
        if (child.stdin) |*stdin_pipe| {
            stdin_pipe.writeStreamingAll(io, data) catch {};
            stdin_pipe.close(io);
            child.stdin = null;
        }
    }

    // Read stdout and stderr
    if (child.stdout) |stdout_pipe| {
        result.stdout_len = readPipe(io, stdout_pipe, &result.stdout);
    }
    if (child.stderr) |stderr_pipe| {
        result.stderr_len = readPipe(io, stderr_pipe, &result.stderr);
    }

    // Wait for child to exit
    const term = child.wait(io) catch {
        result.wall_time_ms = @intCast(@max(0, timestampMs(io) - start));
        return result;
    };

    result.wall_time_ms = @intCast(@max(0, timestampMs(io) - start));

    // Map termination status
    switch (term) {
        .exited => |code| {
            result.exit_code = @intCast(code);
        },
        .signal => |sig| {
            result.exit_code = -@as(i32, @intCast(@intFromEnum(sig)));
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
pub fn spawn(io: std.Io, config: *const SubprocessConfig) ?ProcessHandle {
    if (requiresUnavailablePolicy(config)) return null;
    var argv_buf: [MAX_ARGV][]const u8 = undefined;
    const argc = @min(config.argv.len, MAX_ARGV);
    for (0..argc) |i| {
        argv_buf[i] = config.argv[i];
    }

    const child = std.process.spawn(io, .{
        .argv = argv_buf[0..argc],
        .cwd = if (config.cwd) |cwd| .{ .path = cwd } else .inherit,
        .stdin = if (config.stdin_data != null) .pipe else .close,
        .stdout = .pipe,
        .stderr = .pipe,
        .request_resource_usage_statistics = true,
    }) catch return null;

    return ProcessHandle{
        .child = child,
        .start_time = timestampMs(io),
    };
}

/// Wait for a spawned process to complete.
/// timeout_ms: maximum time to wait (0 = wait indefinitely).
pub fn wait(io: std.Io, handle: *ProcessHandle, timeout_ms: u32) ?SubprocessResult {
    if (timeout_ms != 0) return null;

    var result = SubprocessResult{
        .exit_code = -1,
        .stdout = @as([MAX_OUTPUT]u8, @splat(0)),
        .stdout_len = 0,
        .stderr = @as([MAX_OUTPUT]u8, @splat(0)),
        .stderr_len = 0,
        .wall_time_ms = 0,
        .limit_exceeded = null,
    };

    // Read output pipes
    if (handle.child.stdout) |stdout_pipe| {
        result.stdout_len = readPipe(io, stdout_pipe, &result.stdout);
    }
    if (handle.child.stderr) |stderr_pipe| {
        result.stderr_len = readPipe(io, stderr_pipe, &result.stderr);
    }

    const term = handle.child.wait(io) catch return null;

    result.wall_time_ms = @intCast(@max(0, timestampMs(io) - handle.start_time));

    switch (term) {
        .exited => |code| {
            result.exit_code = @intCast(code);
        },
        .signal => |sig| {
            result.exit_code = -@as(i32, @intCast(@intFromEnum(sig)));
        },
        else => {
            result.exit_code = -1;
        },
    }

    return result;
}

/// Kill a running process.
pub fn kill(io: std.Io, handle: *ProcessHandle) bool {
    if (handle.child.id == null) return false;
    handle.child.kill(io);
    return true;
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
        .stdout = @as([MAX_OUTPUT]u8, @splat(0)),
        .stdout_len = 5,
        .stderr = @as([MAX_OUTPUT]u8, @splat(0)),
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
    const result = run(testing.io, &config);
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
    const result = run(testing.io, &config);
    try testing.expect(result.exit_code != 0);
    try testing.expect(result.limit_exceeded == null);
}

test "subprocess: capture stderr" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const config = SubprocessConfig{
        .argv = &[_][]const u8{ "/bin/sh", "-c", "echo error >&2" },
    };
    const result = run(testing.io, &config);
    try testing.expectEqual(@as(i32, 0), result.exit_code);
    try testing.expect(result.stderr_len > 0);
    try testing.expect(std.mem.startsWith(u8, result.stderrSlice(), "error"));
}

test "subprocess: unsupported isolation fails closed" {
    const config = SubprocessConfig{
        .argv = &.{"/bin/true"},
        .time_limit_sec = 1,
    };
    const result = run(testing.io, &config);
    try testing.expectEqual(@as(i32, -1), result.exit_code);
    try testing.expectEqual(LimitType.policy_unavailable, result.limit_exceeded.?);
}
