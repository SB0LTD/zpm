// Layer 0 — Zig toolchain bootstrapper.
// Uses vtable for all I/O (exec, download, extract, print) so the
// core logic is pure and fully testable without real system calls.
//
// Requirements: 15.1, 15.2, 15.3, 15.4, 15.5, 15.6

// ── Public Types ──

pub const ExecResult = struct {
    exit_code: u8,
    stdout: []const u8,
};

pub const BootstrapVtable = struct {
    exec: *const fn (cmd: []const u8, stdout_buf: []u8) ?ExecResult,
    download: *const fn (url: []const u8, dest_path: []const u8) bool,
    extract: *const fn (archive_path: []const u8, dest_dir: []const u8) bool,
    print: *const fn (msg: []const u8) void,
};

pub const BootstrapResult = enum {
    already_installed,
    installed,
    updated,
    failed,
    offline_no_zig,
};

pub const MINIMUM_ZIG_VERSION = "0.16.0";

const zig_download_url = "https://ziglang.org/download/latest.tar.xz";
const zig_install_dir = "~/.zpm/toolchain";

// ── Bootstrapper ──

pub const ZigBootstrapper = struct {
    vtable: BootstrapVtable,
    offline: bool,
    auto_update: bool,

    /// Ensure Zig is available and meets the minimum version requirement.
    ///
    /// 1. exec "zig version"
    /// 2. If found, parse version, compare >= 0.16.0
    /// 3. If good → .already_installed
    /// 4. If outdated + auto_update → download → .updated
    /// 5. If outdated + !auto_update → print prompt → .failed
    /// 6. If not found + !offline → download → .installed
    /// 7. If not found + offline → .offline_no_zig
    pub fn ensureZig(self: *const ZigBootstrapper) BootstrapResult {
        // Step 1: Try to exec "zig version"
        var stdout_buf: [256]u8 = undefined;
        const exec_result = self.vtable.exec("zig version", &stdout_buf);

        if (exec_result) |result| {
            if (result.exit_code == 0 and result.stdout.len > 0) {
                // Step 2: Parse version from output (e.g. "0.16.0\n" or "0.16.0-dev.123+abc")
                const version = trimVersion(result.stdout);

                // Step 3: Compare against minimum
                const cmp = compareVersions(version, MINIMUM_ZIG_VERSION);
                if (cmp >= 0) {
                    // Good — meets minimum version
                    return .already_installed;
                }

                // Outdated
                if (self.auto_update) {
                    // Step 4: Auto-update
                    if (self.downloadAndInstall()) {
                        return .updated;
                    }
                    self.vtable.print("failed to update zig\n");
                    return .failed;
                }

                // Step 5: Not auto-updating — prompt user
                self.vtable.print("zig version is below minimum (0.16.0). please update.\n");
                return .failed;
            }
        }

        // Zig not found
        if (self.offline) {
            // Step 7: Offline, can't download
            self.vtable.print("zig not found and cannot download in offline mode\n");
            return .offline_no_zig;
        }

        // Step 6: Download and install
        if (self.downloadAndInstall()) {
            return .installed;
        }

        self.vtable.print("failed to download zig — check your internet connection\n");
        return .failed;
    }

    fn downloadAndInstall(self: *const ZigBootstrapper) bool {
        const archive_path = "/tmp/zig-latest.tar.xz";
        if (!self.vtable.download(zig_download_url, archive_path)) {
            return false;
        }
        if (!self.vtable.extract(archive_path, zig_install_dir)) {
            return false;
        }
        return true;
    }
};

// ── Version Helpers ──

/// Trim trailing whitespace and anything after '-' or '+' from version output.
/// "0.16.0\n" → "0.16.0", "0.16.0-dev.123+abc\n" → "0.16.0"
fn trimVersion(raw: []const u8) []const u8 {
    var end: usize = raw.len;

    // Trim trailing whitespace/newlines
    while (end > 0 and (raw[end - 1] == '\n' or raw[end - 1] == '\r' or raw[end - 1] == ' ')) {
        end -= 1;
    }

    // Trim at first '-' or '+' (pre-release/build metadata)
    for (raw[0..end], 0..) |c, i| {
        if (c == '-' or c == '+') {
            end = i;
            break;
        }
    }

    return raw[0..end];
}

/// Parse a single numeric component from a version string starting at `start`.
/// Returns the parsed number and the index after the component (past the dot or end).
fn parseComponent(version: []const u8, start: usize) struct { value: u32, next: usize } {
    var val: u32 = 0;
    var i = start;
    while (i < version.len and version[i] >= '0' and version[i] <= '9') {
        val = val * 10 + @as(u32, version[i] - '0');
        i += 1;
    }
    // Skip the dot separator if present
    if (i < version.len and version[i] == '.') {
        i += 1;
    }
    return .{ .value = val, .next = i };
}

/// Compare two semver version strings (major.minor.patch).
/// Returns: -1 if a < b, 0 if a == b, 1 if a > b
pub fn compareVersions(a: []const u8, b: []const u8) i8 {
    var ai: usize = 0;
    var bi: usize = 0;

    // Compare up to 3 components (major, minor, patch)
    var component: usize = 0;
    while (component < 3) : (component += 1) {
        const pa = parseComponent(a, ai);
        const pb = parseComponent(b, bi);

        if (pa.value < pb.value) return -1;
        if (pa.value > pb.value) return 1;

        ai = pa.next;
        bi = pb.next;
    }

    return 0;
}

// ── Tests ──

const testing = @import("std").testing;

// ── Mock Vtable Infrastructure ──

var mock_print_buf: [1024]u8 = undefined;
var mock_print_len: usize = 0;
var mock_exec_result: ?ExecResult = null;
var mock_download_success: bool = true;
var mock_extract_success: bool = true;

fn resetBootstrapMocks() void {
    mock_print_len = 0;
    mock_exec_result = null;
    mock_download_success = true;
    mock_extract_success = true;
}

fn mockExec(_: []const u8, _: []u8) ?ExecResult {
    return mock_exec_result;
}

fn mockDownload(_: []const u8, _: []const u8) bool {
    return mock_download_success;
}

fn mockExtract(_: []const u8, _: []const u8) bool {
    return mock_extract_success;
}

fn mockPrint(msg: []const u8) void {
    const copy_len = @min(msg.len, mock_print_buf.len - mock_print_len);
    @memcpy(mock_print_buf[mock_print_len .. mock_print_len + copy_len], msg[0..copy_len]);
    mock_print_len += copy_len;
}

fn getPrintOutput() []const u8 {
    return mock_print_buf[0..mock_print_len];
}

const mock_vtable = BootstrapVtable{
    .exec = &mockExec,
    .download = &mockDownload,
    .extract = &mockExtract,
    .print = &mockPrint,
};


// ── ensureZig Tests ──

test "ensureZig: zig at correct version returns already_installed" {
    resetBootstrapMocks();
    mock_exec_result = .{ .exit_code = 0, .stdout = "0.16.0\n" };

    const b = ZigBootstrapper{
        .vtable = mock_vtable,
        .offline = false,
        .auto_update = false,
    };

    const result = b.ensureZig();
    try testing.expectEqual(BootstrapResult.already_installed, result);
    // No output when zig is already good
    try testing.expectEqual(@as(usize, 0), mock_print_len);
}

test "ensureZig: zig above minimum returns already_installed" {
    resetBootstrapMocks();
    mock_exec_result = .{ .exit_code = 0, .stdout = "0.17.0\n" };

    const b = ZigBootstrapper{
        .vtable = mock_vtable,
        .offline = false,
        .auto_update = false,
    };

    const result = b.ensureZig();
    try testing.expectEqual(BootstrapResult.already_installed, result);
}

test "ensureZig: zig not found, online, download succeeds returns installed" {
    resetBootstrapMocks();
    mock_exec_result = null; // zig not found
    mock_download_success = true;
    mock_extract_success = true;

    const b = ZigBootstrapper{
        .vtable = mock_vtable,
        .offline = false,
        .auto_update = false,
    };

    const result = b.ensureZig();
    try testing.expectEqual(BootstrapResult.installed, result);
}

test "ensureZig: outdated zig with auto_update returns updated" {
    resetBootstrapMocks();
    mock_exec_result = .{ .exit_code = 0, .stdout = "0.15.0\n" };
    mock_download_success = true;
    mock_extract_success = true;

    const b = ZigBootstrapper{
        .vtable = mock_vtable,
        .offline = false,
        .auto_update = true,
    };

    const result = b.ensureZig();
    try testing.expectEqual(BootstrapResult.updated, result);
}

test "ensureZig: outdated zig without auto_update returns failed" {
    resetBootstrapMocks();
    mock_exec_result = .{ .exit_code = 0, .stdout = "0.15.0\n" };

    const b = ZigBootstrapper{
        .vtable = mock_vtable,
        .offline = false,
        .auto_update = false,
    };

    const result = b.ensureZig();
    try testing.expectEqual(BootstrapResult.failed, result);
    // Should have printed a message about outdated version
    const output = getPrintOutput();
    try testing.expect(output.len > 0);
}

test "ensureZig: offline with no zig returns offline_no_zig" {
    resetBootstrapMocks();
    mock_exec_result = null; // zig not found

    const b = ZigBootstrapper{
        .vtable = mock_vtable,
        .offline = true,
        .auto_update = false,
    };

    const result = b.ensureZig();
    try testing.expectEqual(BootstrapResult.offline_no_zig, result);
    const output = getPrintOutput();
    try testing.expect(output.len > 0);
}

test "ensureZig: download failure returns failed" {
    resetBootstrapMocks();
    mock_exec_result = null; // zig not found
    mock_download_success = false;

    const b = ZigBootstrapper{
        .vtable = mock_vtable,
        .offline = false,
        .auto_update = false,
    };

    const result = b.ensureZig();
    try testing.expectEqual(BootstrapResult.failed, result);
}

test "ensureZig: extract failure returns failed" {
    resetBootstrapMocks();
    mock_exec_result = null; // zig not found
    mock_download_success = true;
    mock_extract_success = false;

    const b = ZigBootstrapper{
        .vtable = mock_vtable,
        .offline = false,
        .auto_update = false,
    };

    const result = b.ensureZig();
    try testing.expectEqual(BootstrapResult.failed, result);
}

test "ensureZig: dev version with suffix still parses correctly" {
    resetBootstrapMocks();
    mock_exec_result = .{ .exit_code = 0, .stdout = "0.16.0-dev.123+abc\n" };

    const b = ZigBootstrapper{
        .vtable = mock_vtable,
        .offline = false,
        .auto_update = false,
    };

    const result = b.ensureZig();
    try testing.expectEqual(BootstrapResult.already_installed, result);
}

// ── compareVersions Tests ──

test "compareVersions: equal versions" {
    try testing.expectEqual(@as(i8, 0), compareVersions("0.16.0", "0.16.0"));
    try testing.expectEqual(@as(i8, 0), compareVersions("1.0.0", "1.0.0"));
    try testing.expectEqual(@as(i8, 0), compareVersions("0.0.0", "0.0.0"));
}

test "compareVersions: a < b" {
    try testing.expectEqual(@as(i8, -1), compareVersions("0.15.0", "0.16.0"));
    try testing.expectEqual(@as(i8, -1), compareVersions("0.16.0", "0.16.1"));
    try testing.expectEqual(@as(i8, -1), compareVersions("0.16.0", "1.0.0"));
    try testing.expectEqual(@as(i8, -1), compareVersions("0.9.9", "0.10.0"));
}

test "compareVersions: a > b" {
    try testing.expectEqual(@as(i8, 1), compareVersions("0.17.0", "0.16.0"));
    try testing.expectEqual(@as(i8, 1), compareVersions("0.16.1", "0.16.0"));
    try testing.expectEqual(@as(i8, 1), compareVersions("1.0.0", "0.99.99"));
}

test "compareVersions: major version differences" {
    try testing.expectEqual(@as(i8, -1), compareVersions("0.16.0", "1.0.0"));
    try testing.expectEqual(@as(i8, 1), compareVersions("2.0.0", "1.99.99"));
}

// ── Property Tests ──

// **Property 15: Bootstrap Idempotency**
// Validates: Requirement 15.4
// For any system state where Zig >= 0.16.0, calling ensureZig() twice shall
// both return already_installed, produce no output, and trigger no downloads.

var mock_download_call_count: usize = 0;
var mock_extract_call_count: usize = 0;

fn mockCountingDownload(_: []const u8, _: []const u8) bool {
    mock_download_call_count += 1;
    return true;
}

fn mockCountingExtract(_: []const u8, _: []const u8) bool {
    mock_extract_call_count += 1;
    return true;
}

const counting_vtable = BootstrapVtable{
    .exec = &mockExec,
    .download = &mockCountingDownload,
    .extract = &mockCountingExtract,
    .print = &mockPrint,
};

test "property 15: bootstrap idempotency — ensureZig twice with good version" {
    // **Validates: Requirements 15.4**
    const versions = [_][]const u8{
        "0.16.0\n",  "0.17.0\n",  "0.16.1\n",  "1.0.0\n",
        "0.20.0\n",  "0.16.0-dev.100+abc\n",
        "2.0.0\n",   "0.16.5\n",  "0.99.0\n",  "0.16.0-rc1\n",
        "0.18.3\n",  "0.16.2\n",  "3.1.0\n",   "0.17.1\n",
        "0.19.0\n",  "0.16.9\n",  "1.1.0\n",   "0.21.0\n",
        "0.16.3\n",  "0.25.0\n",
    };

    var iter: usize = 0;
    while (iter < 200) : (iter += 1) {
        const version = versions[iter % versions.len];

        resetBootstrapMocks();
        mock_download_call_count = 0;
        mock_extract_call_count = 0;
        mock_exec_result = .{ .exit_code = 0, .stdout = version };

        const b = ZigBootstrapper{
            .vtable = counting_vtable,
            .offline = false,
            .auto_update = false,
        };

        // First call
        const result1 = b.ensureZig();
        try testing.expectEqual(BootstrapResult.already_installed, result1);
        const print_after_first = mock_print_len;

        // Second call
        const result2 = b.ensureZig();
        try testing.expectEqual(BootstrapResult.already_installed, result2);

        // No output on either call
        try testing.expectEqual(@as(usize, 0), print_after_first);
        try testing.expectEqual(@as(usize, 0), mock_print_len);

        // No download/extract calls
        try testing.expectEqual(@as(usize, 0), mock_download_call_count);
        try testing.expectEqual(@as(usize, 0), mock_extract_call_count);
    }
}
