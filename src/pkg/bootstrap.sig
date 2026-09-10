// Layer 0 — Sig toolchain bootstrapper.
// Uses vtable for all I/O (exec, download, extract, print) so the
// core logic is pure and fully testable without real system calls.
//
// Requirements: 15.1, 15.2, 15.3, 15.4, 15.5, 15.6

const builtin = @import("builtin");

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
    offline_no_sig,
};

/// Oldest compiler known to provide the native, bounded `sig build` API used
/// by zpm 0.3. The installed toolchain may (and normally should) be newer.
pub const MINIMUM_SIG_VERSION = "0.5.2";

const sig_install_dir = ".zpm/toolchain";

fn sigDownloadUrl() []const u8 {
    return switch (builtin.os.tag) {
        .windows => switch (builtin.cpu.arch) {
            .x86_64 => "https://github.com/SB0LTD/sig/releases/latest/download/sig-x86_64-windows.zip",
            else => "https://github.com/SB0LTD/sig/releases/latest/download/sig-aarch64-windows.zip",
        },
        .macos => switch (builtin.cpu.arch) {
            .x86_64 => "https://github.com/SB0LTD/sig/releases/latest/download/sig-x86_64-macos.tar.xz",
            else => "https://github.com/SB0LTD/sig/releases/latest/download/sig-aarch64-macos.tar.xz",
        },
        else => switch (builtin.cpu.arch) {
            .x86_64 => "https://github.com/SB0LTD/sig/releases/latest/download/sig-x86_64-linux.tar.xz",
            else => "https://github.com/SB0LTD/sig/releases/latest/download/sig-aarch64-linux.tar.xz",
        },
    };
}

fn sigArchivePath() []const u8 {
    return if (builtin.os.tag == .windows) "sig-latest.zip" else "/tmp/sig-latest.tar.xz";
}

// ── Bootstrapper ──

pub const SigBootstrapper = struct {
    vtable: BootstrapVtable,
    offline: bool,
    auto_update: bool,

    /// Ensure Sig is available and meets the minimum version requirement.
    ///
    /// 1. exec "sig version"
    /// 2. If found, parse version, compare >= MINIMUM_SIG_VERSION
    /// 3. If good → .already_installed
    /// 4. If outdated + auto_update → download → .updated
    /// 5. If outdated + !auto_update → print prompt → .failed
    /// 6. If not found + !offline → download → .installed
    /// 7. If not found + offline → .offline_no_sig
    pub fn ensureSig(self: *const SigBootstrapper) BootstrapResult {
        // Step 1: Try to exec "sig version"
        var stdout_buf: [256]u8 = undefined;
        const exec_result = self.vtable.exec("sig version", &stdout_buf);

        if (exec_result) |result| {
            if (result.exit_code == 0 and result.stdout.len > 0) {
                // Step 2: Validate the Sig version banner without allocating.
                const version = trimVersion(result.stdout);

                // Step 3: Compare against minimum
                const cmp = compareVersions(version, MINIMUM_SIG_VERSION);
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
                    self.vtable.print("failed to update sig\n");
                    return .failed;
                }

                // Step 5: Not auto-updating — prompt user
                self.vtable.print("sig version is below minimum (0.5.2). please update.\n");
                return .failed;
            }
        }

        // Sig not found
        if (self.offline) {
            // Step 7: Offline, can't download
            self.vtable.print("sig not found and cannot download in offline mode\n");
            return .offline_no_sig;
        }

        // Step 6: Download and install
        if (self.downloadAndInstall()) {
            return .installed;
        }

        self.vtable.print("failed to download sig — check your internet connection\n");
        return .failed;
    }

    fn downloadAndInstall(self: *const SigBootstrapper) bool {
        const archive_path = sigArchivePath();
        if (!self.vtable.download(sigDownloadUrl(), archive_path)) {
            return false;
        }
        if (!self.vtable.extract(archive_path, sig_install_dir)) {
            return false;
        }
        return true;
    }
};

// ── Version Helpers ──

/// Accept only the Sig banner. A bare Zig version cannot establish that the
/// native Sig build API is available. Invalid or overflowing versions fail closed.
pub fn trimVersion(raw: []const u8) []const u8 {
    if (raw.len < 5 or raw[0] != 's' or raw[1] != 'i' or raw[2] != 'g' or raw[3] != ' ') return raw[0..0];
    var end: usize = 4;
    var component: usize = 0;
    while (component < 3) : (component += 1) {
        var digits: usize = 0;
        while (end < raw.len and raw[end] >= '0' and raw[end] <= '9') : (end += 1) {
            digits += 1;
            if (digits > 9) return raw[0..0];
        }
        if (digits == 0) return raw[0..0];
        if (component < 2) {
            if (end == raw.len or raw[end] != '.') return raw[0..0];
            end += 1;
        }
    }
    if (end < raw.len and raw[end] != ' ' and raw[end] != '\r' and raw[end] != '\n' and raw[end] != '-' and raw[end] != '+') return raw[0..0];
    return raw[4..end];
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


// ── ensureSig Tests ──

test "ensureSig: sig at correct version returns already_installed" {
    resetBootstrapMocks();
    mock_exec_result = .{ .exit_code = 0, .stdout = "sig 0.5.2 (zig 0.17.0)\n" };

    const b = SigBootstrapper{
        .vtable = mock_vtable,
        .offline = false,
        .auto_update = false,
    };

    const result = b.ensureSig();
    try testing.expectEqual(BootstrapResult.already_installed, result);
    // No output when Sig is already good
    try testing.expectEqual(@as(usize, 0), mock_print_len);
}

test "ensureSig: sig above minimum returns already_installed" {
    resetBootstrapMocks();
    mock_exec_result = .{ .exit_code = 0, .stdout = "sig 0.5.3 (zig 0.17.0)\n" };

    const b = SigBootstrapper{
        .vtable = mock_vtable,
        .offline = false,
        .auto_update = false,
    };

    const result = b.ensureSig();
    try testing.expectEqual(BootstrapResult.already_installed, result);
}

test "ensureSig: sig not found, online, download succeeds returns installed" {
    resetBootstrapMocks();
    mock_exec_result = null; // sig not found
    mock_download_success = true;
    mock_extract_success = true;

    const b = SigBootstrapper{
        .vtable = mock_vtable,
        .offline = false,
        .auto_update = false,
    };

    const result = b.ensureSig();
    try testing.expectEqual(BootstrapResult.installed, result);
}

test "ensureSig: outdated sig with auto_update returns updated" {
    resetBootstrapMocks();
    mock_exec_result = .{ .exit_code = 0, .stdout = "sig 0.2.0 (zig 0.17.0)\n" };
    mock_download_success = true;
    mock_extract_success = true;

    const b = SigBootstrapper{
        .vtable = mock_vtable,
        .offline = false,
        .auto_update = true,
    };

    const result = b.ensureSig();
    try testing.expectEqual(BootstrapResult.updated, result);
}

test "ensureSig: outdated sig without auto_update returns failed" {
    resetBootstrapMocks();
    mock_exec_result = .{ .exit_code = 0, .stdout = "sig 0.2.0 (zig 0.17.0)\n" };

    const b = SigBootstrapper{
        .vtable = mock_vtable,
        .offline = false,
        .auto_update = false,
    };

    const result = b.ensureSig();
    try testing.expectEqual(BootstrapResult.failed, result);
    // Should have printed a message about outdated version
    const output = getPrintOutput();
    try testing.expect(output.len > 0);
}

test "ensureSig: offline with no sig returns offline_no_sig" {
    resetBootstrapMocks();
    mock_exec_result = null; // sig not found

    const b = SigBootstrapper{
        .vtable = mock_vtable,
        .offline = true,
        .auto_update = false,
    };

    const result = b.ensureSig();
    try testing.expectEqual(BootstrapResult.offline_no_sig, result);
    const output = getPrintOutput();
    try testing.expect(output.len > 0);
}

test "ensureSig: download failure returns failed" {
    resetBootstrapMocks();
    mock_exec_result = null; // sig not found
    mock_download_success = false;

    const b = SigBootstrapper{
        .vtable = mock_vtable,
        .offline = false,
        .auto_update = false,
    };

    const result = b.ensureSig();
    try testing.expectEqual(BootstrapResult.failed, result);
}

test "ensureSig: extract failure returns failed" {
    resetBootstrapMocks();
    mock_exec_result = null; // sig not found
    mock_download_success = true;
    mock_extract_success = false;

    const b = SigBootstrapper{
        .vtable = mock_vtable,
        .offline = false,
        .auto_update = false,
    };

    const result = b.ensureSig();
    try testing.expectEqual(BootstrapResult.failed, result);
}

test "ensureSig: dev version with suffix still parses correctly" {
    resetBootstrapMocks();
    mock_exec_result = .{ .exit_code = 0, .stdout = "sig 0.5.3-dev.123+abc (zig 0.17.0)\n" };

    const b = SigBootstrapper{
        .vtable = mock_vtable,
        .offline = false,
        .auto_update = false,
    };

    const result = b.ensureSig();
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
// For any system state where Sig >= 0.5.2, calling ensureSig() twice shall
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

test "property 15: bootstrap idempotency — ensureSig twice with good version" {
    // **Validates: Requirements 15.4**
    const versions = [_][]const u8{
        "sig 0.5.2 (zig 0.17.0)\n", "sig 0.5.3 (zig 0.17.0)\n",
        "sig 0.5.3-dev.100+abc (zig 0.17.0)\n", "sig 0.6.0\n", "sig 1.0.0\n",
    };

    var iter: usize = 0;
    while (iter < 200) : (iter += 1) {
        const version = versions[iter % versions.len];

        resetBootstrapMocks();
        mock_download_call_count = 0;
        mock_extract_call_count = 0;
        mock_exec_result = .{ .exit_code = 0, .stdout = version };

        const b = SigBootstrapper{
            .vtable = counting_vtable,
            .offline = false,
            .auto_update = false,
        };

        // First call
        const result1 = b.ensureSig();
        try testing.expectEqual(BootstrapResult.already_installed, result1);
        const print_after_first = mock_print_len;

        // Second call
        const result2 = b.ensureSig();
        try testing.expectEqual(BootstrapResult.already_installed, result2);

        // No output on either call
        try testing.expectEqual(@as(usize, 0), print_after_first);
        try testing.expectEqual(@as(usize, 0), mock_print_len);

        // No download/extract calls
        try testing.expectEqual(@as(usize, 0), mock_download_call_count);
        try testing.expectEqual(@as(usize, 0), mock_extract_call_count);
    }
}

test "Sig version gate rejects unrelated and malformed output" {
    for ([_][]const u8{ "0.17.0", "zig 0.17.0", "hello 3.0.0", "sig 0.5", "sig 0.5.3oops", "sig 9999999999999999.0.0" }) |output| {
        try testing.expectEqual(@as(usize, 0), trimVersion(output).len);
    }
    try testing.expectEqualStrings("0.5.3", trimVersion("sig 0.5.3 (zig 0.17.0)"));
}
