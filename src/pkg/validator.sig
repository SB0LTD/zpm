// Layer 0 — Pure validation logic for zpm package protocol.
// No I/O, no allocator. Operates on in-memory data structures.
//
// Validates layer ordering, system library declarations, constraint
// adherence, export-module consistency, and platform-library consistency.

const manifest = @import("manifest.sig");
const PackageManifest = manifest.PackageManifest;
const Platform = manifest.Platform;
const Constraints = manifest.Constraints;

// ── Input Types ──
// These represent pre-parsed data passed in by the caller.
// The validator never touches the filesystem.

/// Metadata about a single zpm dependency, resolved before validation.
pub const DepMeta = struct {
    scope: []const u8,
    name: []const u8,
    layer: u2,
};

/// Result of scanning a source file for constraint violations.
pub const SourceScanResult = struct {
    file_path: []const u8,
    has_std_io_import: bool = false,
    has_std_fs_import: bool = false,
    has_allocator_param: bool = false,
};

// ── Validation Error ──

pub const ValidationErrorTag = enum {
    layer_violation,
    missing_syslib,
    std_io_violation,
    allocator_violation,
    export_mismatch,
    platform_library_violation,
};

pub const ValidationError = struct {
    tag: ValidationErrorTag,
    message: []const u8,
    /// Context field 1 — meaning depends on tag:
    ///   layer_violation: dependency scoped name
    ///   missing_syslib: library name
    ///   std_io_violation: file path
    ///   allocator_violation: file path
    ///   export_mismatch: export name
    ///   platform_library_violation: library name (or empty for "any + syslibs")
    detail: []const u8 = "",
};

// ── Validation Result ──

const max_errors = 32;

pub const ValidationResult = struct {
    errors: [max_errors]ValidationError = undefined,
    count: usize = 0,

    pub fn ok(self: *const ValidationResult) bool {
        return self.count == 0;
    }

    pub fn add(self: *ValidationResult, tag: ValidationErrorTag, message: []const u8, detail: []const u8) void {
        if (self.count < max_errors) {
            self.errors[self.count] = .{ .tag = tag, .message = message, .detail = detail };
            self.count += 1;
        }
    }

    pub fn slice(self: *const ValidationResult) []const ValidationError {
        return self.errors[0..self.count];
    }
};

// ── Allowed Windows System Libraries ──

const allowed_windows_syslibs = [_][]const u8{
    "kernel32",
    "gdi32",
    "user32",
    "shell32",
    "opengl32",
    "winhttp",
    "bcrypt",
    "ws2_32",
};

// ── Validator ──

/// Validates a package manifest against the zpm protocol rules.
///
/// All inputs are pre-parsed in-memory data — no filesystem access.
///
/// Parameters:
///   - pkg: The package manifest being validated.
///   - dep_metas: Resolved metadata for each zpm dependency (scope, name, layer).
///   - build_syslibs: System library names found via linkSystemLibrary in build.zig.
///   - source_scans: Scan results for source files (std.io/fs imports, allocator params).
///   - build_modules: Module names declared in build.zig (for export validation).
pub fn validate(
    pkg: *const PackageManifest,
    dep_metas: []const DepMeta,
    build_syslibs: []const []const u8,
    source_scans: []const SourceScanResult,
    build_modules: []const []const u8,
) ValidationResult {
    var result = ValidationResult{};

    // Rule 1: Layer ordering — dep.layer <= pkg.layer for all zpm_dependencies
    for (dep_metas) |dep| {
        if (dep.layer > pkg.layer) {
            result.add(
                .layer_violation,
                "dependency has higher layer than package",
                dep.name,
            );
        }
    }

    // Rule 2: System library completeness — build.zig syslibs ⊆ manifest syslibs
    for (build_syslibs) |lib| {
        if (!containsStr(pkg.system_libraries, lib)) {
            result.add(
                .missing_syslib,
                "system library linked in build.zig but not declared in manifest",
                lib,
            );
        }
    }

    // Rule 3: no_std_io constraint — scan for @import("std").io / .fs
    if (pkg.constraints.no_std_io) {
        for (source_scans) |scan| {
            if (scan.has_std_io_import or scan.has_std_fs_import) {
                result.add(
                    .std_io_violation,
                    "source file imports std.io or std.fs but no_std_io is true",
                    scan.file_path,
                );
            }
        }
    }

    // Rule 4: no_allocator constraint — scan for std.mem.Allocator params
    if (pkg.constraints.no_allocator) {
        for (source_scans) |scan| {
            if (scan.has_allocator_param) {
                result.add(
                    .allocator_violation,
                    "public function accepts std.mem.Allocator but no_allocator is true",
                    scan.file_path,
                );
            }
        }
    }

    // Rule 5: Export-module consistency — every export must match a build.zig module
    for (pkg.exports) |export_name| {
        if (!containsStr(build_modules, export_name)) {
            result.add(
                .export_mismatch,
                "export entry has no matching module in build.zig",
                export_name,
            );
        }
    }

    // Rule 6: Platform-library consistency
    switch (pkg.platform) {
        .windows => {
            // Only allowed Windows syslibs
            for (pkg.system_libraries) |lib| {
                if (!isAllowedWindowsSyslib(lib)) {
                    result.add(
                        .platform_library_violation,
                        "system library not in allowed Windows set",
                        lib,
                    );
                }
            }
        },
        .any => {
            // No platform-specific syslibs allowed
            if (pkg.system_libraries.len > 0) {
                result.add(
                    .platform_library_violation,
                    "platform is .any but system_libraries is not empty",
                    "",
                );
            }
        },
        // linux, macos — no specific restrictions defined yet
        .linux, .macos => {},
    }

    return result;
}

// ── Helpers ──

fn containsStr(haystack: []const []const u8, needle: []const u8) bool {
    for (haystack) |item| {
        if (strEql(item, needle)) return true;
    }
    return false;
}

fn strEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (ca != cb) return false;
    }
    return true;
}

fn isAllowedWindowsSyslib(lib: []const u8) bool {
    for (allowed_windows_syslibs) |allowed| {
        if (strEql(lib, allowed)) return true;
    }
    return false;
}


// ── Tests ──

const std = @import("std");
const testing = std.testing;

// Helper to create a minimal valid manifest for testing.
fn testManifest() PackageManifest {
    return .{
        .protocol_version = 1,
        .scope = "zpm",
        .name = "window",
        .version = "0.1.0",
        .layer = 1,
        .platform = .windows,
        .system_libraries = &.{ "kernel32", "gdi32" },
        .zpm_dependencies = &.{ "@zpm/win32", "@zpm/gl" },
        .exports = &.{"window"},
        .constraints = .{ .no_allocator = false, .no_std_io = false },
    };
}

// ── Rule 1: Layer ordering ──

test "validate: all deps at lower or equal layer passes" {
    const pkg = testManifest(); // layer 1
    const deps = [_]DepMeta{
        .{ .scope = "zpm", .name = "win32", .layer = 0 },
        .{ .scope = "zpm", .name = "gl", .layer = 1 },
    };
    const result = validate(&pkg, &deps, pkg.system_libraries, &.{}, &.{"window"});
    try testing.expect(result.ok());
}

test "validate: dep at higher layer is rejected" {
    const pkg = testManifest(); // layer 1
    const deps = [_]DepMeta{
        .{ .scope = "zpm", .name = "primitives", .layer = 2 },
    };
    const result = validate(&pkg, &deps, pkg.system_libraries, &.{}, &.{"window"});
    try testing.expect(!result.ok());
    try testing.expectEqual(@as(usize, 1), result.count);
    try testing.expectEqual(ValidationErrorTag.layer_violation, result.slice()[0].tag);
    try testing.expectEqualStrings("primitives", result.slice()[0].detail);
}

test "validate: layer 0 package with layer 0 dep passes" {
    var pkg = testManifest();
    pkg.layer = 0;
    pkg.platform = .any;
    pkg.system_libraries = &.{};
    pkg.exports = &.{};
    const deps = [_]DepMeta{
        .{ .scope = "zpm", .name = "math", .layer = 0 },
    };
    const result = validate(&pkg, &deps, &.{}, &.{}, &.{});
    try testing.expect(result.ok());
}

test "validate: multiple layer violations reported" {
    var pkg = testManifest();
    pkg.layer = 0;
    pkg.platform = .any;
    pkg.system_libraries = &.{};
    pkg.exports = &.{};
    const deps = [_]DepMeta{
        .{ .scope = "zpm", .name = "win32", .layer = 1 },
        .{ .scope = "zpm", .name = "primitives", .layer = 2 },
    };
    const result = validate(&pkg, &deps, &.{}, &.{}, &.{});
    try testing.expectEqual(@as(usize, 2), result.count);
}

// ── Rule 2: System library completeness ──

test "validate: all build syslibs declared in manifest passes" {
    const pkg = testManifest();
    const build_syslibs = [_][]const u8{ "kernel32", "gdi32" };
    const result = validate(&pkg, &.{}, &build_syslibs, &.{}, &.{"window"});
    try testing.expect(result.ok());
}

test "validate: undeclared build syslib is rejected" {
    const pkg = testManifest(); // declares kernel32, gdi32
    const build_syslibs = [_][]const u8{ "kernel32", "gdi32", "user32" };
    const result = validate(&pkg, &.{}, &build_syslibs, &.{}, &.{"window"});
    try testing.expect(!result.ok());
    try testing.expectEqual(ValidationErrorTag.missing_syslib, result.slice()[0].tag);
    try testing.expectEqualStrings("user32", result.slice()[0].detail);
}

test "validate: empty build syslibs with declared manifest syslibs passes" {
    const pkg = testManifest();
    const result = validate(&pkg, &.{}, &.{}, &.{}, &.{"window"});
    try testing.expect(result.ok());
}

// ── Rule 3: no_std_io constraint ──

test "validate: no_std_io false ignores std.io imports" {
    var pkg = testManifest();
    pkg.constraints.no_std_io = false;
    const scans = [_]SourceScanResult{
        .{ .file_path = "src/foo.zig", .has_std_io_import = true },
    };
    const result = validate(&pkg, &.{}, pkg.system_libraries, &scans, &.{"window"});
    try testing.expect(result.ok());
}

test "validate: no_std_io true rejects std.io import" {
    var pkg = testManifest();
    pkg.constraints.no_std_io = true;
    const scans = [_]SourceScanResult{
        .{ .file_path = "src/foo.zig", .has_std_io_import = true },
    };
    const result = validate(&pkg, &.{}, pkg.system_libraries, &scans, &.{"window"});
    try testing.expect(!result.ok());
    try testing.expectEqual(ValidationErrorTag.std_io_violation, result.slice()[0].tag);
    try testing.expectEqualStrings("src/foo.zig", result.slice()[0].detail);
}

test "validate: no_std_io true rejects std.fs import" {
    var pkg = testManifest();
    pkg.constraints.no_std_io = true;
    const scans = [_]SourceScanResult{
        .{ .file_path = "src/bar.zig", .has_std_fs_import = true },
    };
    const result = validate(&pkg, &.{}, pkg.system_libraries, &scans, &.{"window"});
    try testing.expect(!result.ok());
    try testing.expectEqual(ValidationErrorTag.std_io_violation, result.slice()[0].tag);
}

test "validate: no_std_io true with clean sources passes" {
    var pkg = testManifest();
    pkg.constraints.no_std_io = true;
    const scans = [_]SourceScanResult{
        .{ .file_path = "src/clean.zig" },
    };
    const result = validate(&pkg, &.{}, pkg.system_libraries, &scans, &.{"window"});
    try testing.expect(result.ok());
}

// ── Rule 4: no_allocator constraint ──

test "validate: no_allocator false ignores allocator params" {
    var pkg = testManifest();
    pkg.constraints.no_allocator = false;
    const scans = [_]SourceScanResult{
        .{ .file_path = "src/alloc.zig", .has_allocator_param = true },
    };
    const result = validate(&pkg, &.{}, pkg.system_libraries, &scans, &.{"window"});
    try testing.expect(result.ok());
}

test "validate: no_allocator true rejects allocator param" {
    var pkg = testManifest();
    pkg.constraints.no_allocator = true;
    const scans = [_]SourceScanResult{
        .{ .file_path = "src/alloc.zig", .has_allocator_param = true },
    };
    const result = validate(&pkg, &.{}, pkg.system_libraries, &scans, &.{"window"});
    try testing.expect(!result.ok());
    try testing.expectEqual(ValidationErrorTag.allocator_violation, result.slice()[0].tag);
    try testing.expectEqualStrings("src/alloc.zig", result.slice()[0].detail);
}

test "validate: no_allocator true with clean sources passes" {
    var pkg = testManifest();
    pkg.constraints.no_allocator = true;
    const scans = [_]SourceScanResult{
        .{ .file_path = "src/clean.zig" },
    };
    const result = validate(&pkg, &.{}, pkg.system_libraries, &scans, &.{"window"});
    try testing.expect(result.ok());
}

// ── Rule 5: Export-module consistency ──

test "validate: all exports match build modules passes" {
    const pkg = testManifest(); // exports: {"window"}
    const modules = [_][]const u8{"window"};
    const result = validate(&pkg, &.{}, pkg.system_libraries, &.{}, &modules);
    try testing.expect(result.ok());
}

test "validate: export with no matching module is rejected" {
    const pkg = testManifest(); // exports: {"window"}
    const modules = [_][]const u8{"other"};
    const result = validate(&pkg, &.{}, pkg.system_libraries, &.{}, &modules);
    try testing.expect(!result.ok());
    try testing.expectEqual(ValidationErrorTag.export_mismatch, result.slice()[0].tag);
    try testing.expectEqualStrings("window", result.slice()[0].detail);
}

test "validate: empty exports always passes rule 5" {
    var pkg = testManifest();
    pkg.exports = &.{};
    const result = validate(&pkg, &.{}, pkg.system_libraries, &.{}, &.{});
    try testing.expect(result.ok());
}

// ── Rule 6: Platform-library consistency ──

test "validate: windows platform with allowed syslibs passes" {
    const pkg = testManifest(); // platform=windows, syslibs=kernel32,gdi32
    const result = validate(&pkg, &.{}, pkg.system_libraries, &.{}, &.{"window"});
    try testing.expect(result.ok());
}

test "validate: windows platform with disallowed syslib is rejected" {
    var pkg = testManifest();
    pkg.system_libraries = &.{ "kernel32", "libcurl" };
    const result = validate(&pkg, &.{}, pkg.system_libraries, &.{}, &.{"window"});
    try testing.expect(!result.ok());
    try testing.expectEqual(ValidationErrorTag.platform_library_violation, result.slice()[0].tag);
    try testing.expectEqualStrings("libcurl", result.slice()[0].detail);
}

test "validate: any platform with empty syslibs passes" {
    var pkg = testManifest();
    pkg.platform = .any;
    pkg.system_libraries = &.{};
    const result = validate(&pkg, &.{}, &.{}, &.{}, &.{"window"});
    try testing.expect(result.ok());
}

test "validate: any platform with syslibs is rejected" {
    var pkg = testManifest();
    pkg.platform = .any;
    // system_libraries still has kernel32, gdi32
    const result = validate(&pkg, &.{}, &.{}, &.{}, &.{"window"});
    try testing.expect(!result.ok());
    try testing.expectEqual(ValidationErrorTag.platform_library_violation, result.slice()[0].tag);
}

test "validate: linux platform with any syslibs passes (no restrictions)" {
    var pkg = testManifest();
    pkg.platform = .linux;
    pkg.system_libraries = &.{"libfoo"};
    const result = validate(&pkg, &.{}, pkg.system_libraries, &.{}, &.{"window"});
    try testing.expect(result.ok());
}

// ── Combined: all rules pass ──

test "validate: fully valid package returns empty errors" {
    const pkg = testManifest();
    const deps = [_]DepMeta{
        .{ .scope = "zpm", .name = "win32", .layer = 0 },
        .{ .scope = "zpm", .name = "gl", .layer = 1 },
    };
    const build_syslibs = [_][]const u8{ "kernel32", "gdi32" };
    const modules = [_][]const u8{"window"};
    const result = validate(&pkg, &deps, &build_syslibs, &.{}, &modules);
    try testing.expect(result.ok());
    try testing.expectEqual(@as(usize, 0), result.count);
}

// ── Combined: multiple rules violated ──

test "validate: multiple rule violations reported together" {
    var pkg = testManifest();
    pkg.layer = 0;
    pkg.platform = .any;
    pkg.constraints.no_std_io = true;
    pkg.constraints.no_allocator = true;
    // layer 0 with syslibs + platform .any → platform violation
    // exports "window" but no modules → export mismatch
    // dep at layer 1 → layer violation
    const deps = [_]DepMeta{
        .{ .scope = "zpm", .name = "win32", .layer = 1 },
    };
    const build_syslibs = [_][]const u8{"opengl32"};
    const scans = [_]SourceScanResult{
        .{ .file_path = "src/io.zig", .has_std_io_import = true, .has_allocator_param = true },
    };
    const result = validate(&pkg, &deps, &build_syslibs, &scans, &.{});
    // Expect: layer_violation, missing_syslib (opengl32 not in manifest syslibs for layer 0 pkg),
    //         std_io_violation, allocator_violation, export_mismatch, platform_library_violation
    try testing.expect(!result.ok());
    try testing.expect(result.count >= 4);
}

// ── Edge cases ──

test "validate: empty everything passes" {
    var pkg = testManifest();
    pkg.layer = 0;
    pkg.platform = .any;
    pkg.system_libraries = &.{};
    pkg.zpm_dependencies = &.{};
    pkg.exports = &.{};
    pkg.constraints = .{};
    const result = validate(&pkg, &.{}, &.{}, &.{}, &.{});
    try testing.expect(result.ok());
}

test "validate: all 8 allowed windows syslibs accepted" {
    var pkg = testManifest();
    pkg.system_libraries = &.{ "kernel32", "gdi32", "user32", "shell32", "opengl32", "winhttp", "bcrypt", "ws2_32" };
    const build_syslibs = [_][]const u8{ "kernel32", "gdi32", "user32", "shell32", "opengl32", "winhttp", "bcrypt", "ws2_32" };
    const modules = [_][]const u8{"window"};
    const result = validate(&pkg, &.{}, &build_syslibs, &.{}, &modules);
    try testing.expect(result.ok());
}

// ── Property Tests ──

test "property: layer monotonicity — rejects all upward-layer edges (randomized)" {
    // Property 2: For any package P and dependency D, if D.layer > P.layer
    // the validator must report a layer_violation. Generate random dependency
    // graphs with packages at layers 0-2 and random deps, ensure every
    // upward-layer edge is caught.
    //
    // Validates: Requirements 4.4, 6.1

    var prng = std.Random.DefaultPrng.init(0x1A7E_B001);
    const rand = prng.random();

    const iterations = 300;
    for (0..iterations) |_| {
        // Random package layer 0-2
        const pkg_layer: u2 = @intCast(rand.intRangeAtMost(u32, 0, 2));

        // Generate 1-6 random dependencies at random layers 0-2
        const num_deps = rand.intRangeAtMost(usize, 1, 6);
        var deps: [6]DepMeta = undefined;
        var expected_violations: usize = 0;
        for (0..num_deps) |d| {
            const dep_layer: u2 = @intCast(rand.intRangeAtMost(u32, 0, 2));
            deps[d] = .{ .scope = "test", .name = "dep", .layer = dep_layer };
            if (dep_layer > pkg_layer) expected_violations += 1;
        }

        // Build a minimal valid manifest at the chosen layer
        var pkg = testManifest();
        pkg.layer = pkg_layer;
        pkg.platform = .any;
        pkg.system_libraries = &.{};
        pkg.exports = &.{};

        const result = validate(&pkg, deps[0..num_deps], &.{}, &.{}, &.{});

        // Count actual layer violations in result
        var actual_violations: usize = 0;
        for (result.slice()) |err| {
            if (err.tag == .layer_violation) actual_violations += 1;
        }

        if (actual_violations != expected_violations) {
            std.debug.print("Property 2 failed: pkg.layer={}, deps={}, expected {} violations, got {}\n", .{ pkg_layer, num_deps, expected_violations, actual_violations });
            return error.TestUnexpectedResult;
        }
    }
}

test "property: system library completeness — reports all missing libs (randomized)" {
    // Property 5: For any package, the set of system_libraries declared in
    // the manifest must be a superset of the libraries linked in build.zig.
    // Every library in build_syslibs but not in manifest.system_libraries
    // must be reported as missing_syslib.
    //
    // Validates: Requirements 6.3, 6.4

    var prng = std.Random.DefaultPrng.init(0x5151_1B05);
    const rand = prng.random();

    const all_libs = [_][]const u8{ "kernel32", "gdi32", "user32", "shell32", "opengl32", "winhttp", "bcrypt", "ws2_32" };

    const iterations = 300;
    for (0..iterations) |_| {
        // Pick a random subset of libs for the manifest declaration
        var manifest_libs: [8][]const u8 = undefined;
        var manifest_count: usize = 0;
        for (all_libs) |lib| {
            if (rand.boolean()) {
                manifest_libs[manifest_count] = lib;
                manifest_count += 1;
            }
        }

        // Pick a random subset of libs for build.zig linkSystemLibrary calls
        var build_libs: [8][]const u8 = undefined;
        var build_count: usize = 0;
        for (all_libs) |lib| {
            if (rand.boolean()) {
                build_libs[build_count] = lib;
                build_count += 1;
            }
        }

        // Count expected missing: in build but not in manifest
        var expected_missing: usize = 0;
        for (build_libs[0..build_count]) |blib| {
            var found = false;
            for (manifest_libs[0..manifest_count]) |mlib| {
                if (strEql(blib, mlib)) {
                    found = true;
                    break;
                }
            }
            if (!found) expected_missing += 1;
        }

        var pkg = testManifest();
        pkg.platform = .windows;
        pkg.system_libraries = manifest_libs[0..manifest_count];
        pkg.exports = &.{};

        const result = validate(&pkg, &.{}, build_libs[0..build_count], &.{}, &.{});

        // Count actual missing_syslib errors
        var actual_missing: usize = 0;
        for (result.slice()) |err| {
            if (err.tag == .missing_syslib) actual_missing += 1;
        }

        if (actual_missing != expected_missing) {
            std.debug.print("Property 5 failed: manifest has {} libs, build has {} libs, expected {} missing, got {}\n", .{ manifest_count, build_count, expected_missing, actual_missing });
            return error.TestUnexpectedResult;
        }
    }
}

test "property: constraint adherence — detects std.io and allocator violations (randomized)" {
    // Property 9: When no_std_io is set, every source file with std.io/std.fs
    // imports must be reported. When no_allocator is set, every source file
    // with allocator params must be reported. When constraints are off,
    // no violations should be reported for those rules.
    //
    // Validates: Requirements 6.5, 6.6

    var prng = std.Random.DefaultPrng.init(0xC005_7BA1);
    const rand = prng.random();

    const file_paths = [_][]const u8{ "src/a.zig", "src/b.zig", "src/c.zig", "src/d.zig" };

    const iterations = 400;
    for (0..iterations) |_| {
        // Random constraint settings
        const no_std_io = rand.boolean();
        const no_allocator = rand.boolean();

        // Generate 1-4 random source scan results
        const num_files = rand.intRangeAtMost(usize, 1, 4);
        var scans: [4]SourceScanResult = undefined;
        var expected_io_violations: usize = 0;
        var expected_alloc_violations: usize = 0;

        for (0..num_files) |f| {
            const has_io = rand.boolean();
            const has_fs = rand.boolean();
            const has_alloc = rand.boolean();
            scans[f] = .{
                .file_path = file_paths[f],
                .has_std_io_import = has_io,
                .has_std_fs_import = has_fs,
                .has_allocator_param = has_alloc,
            };
            if (no_std_io and (has_io or has_fs)) expected_io_violations += 1;
            if (no_allocator and has_alloc) expected_alloc_violations += 1;
        }

        var pkg = testManifest();
        pkg.platform = .any;
        pkg.system_libraries = &.{};
        pkg.exports = &.{};
        pkg.constraints = .{ .no_std_io = no_std_io, .no_allocator = no_allocator };

        const result = validate(&pkg, &.{}, &.{}, scans[0..num_files], &.{});

        var actual_io: usize = 0;
        var actual_alloc: usize = 0;
        for (result.slice()) |err| {
            if (err.tag == .std_io_violation) actual_io += 1;
            if (err.tag == .allocator_violation) actual_alloc += 1;
        }

        if (actual_io != expected_io_violations or actual_alloc != expected_alloc_violations) {
            std.debug.print("Property 9 failed: no_std_io={}, no_allocator={}, files={}\n", .{ no_std_io, no_allocator, num_files });
            std.debug.print("  expected io={} alloc={}, got io={} alloc={}\n", .{ expected_io_violations, expected_alloc_violations, actual_io, actual_alloc });
            return error.TestUnexpectedResult;
        }
    }
}

test "property: export-module consistency — reports all mismatches (randomized)" {
    // Property 10: Every entry in exports must match a module name in
    // build.zig. The validator must report every export that has no
    // matching module.
    //
    // Validates: Requirement 6.7

    var prng = std.Random.DefaultPrng.init(0xE4_00B710);
    const rand = prng.random();

    const all_names = [_][]const u8{ "window", "core", "gl", "timer", "input", "color", "text", "icon" };

    const iterations = 300;
    for (0..iterations) |_| {
        // Pick random subset for exports
        var exports: [8][]const u8 = undefined;
        var export_count: usize = 0;
        for (all_names) |name| {
            if (rand.boolean()) {
                exports[export_count] = name;
                export_count += 1;
            }
        }

        // Pick random subset for build modules
        var modules: [8][]const u8 = undefined;
        var module_count: usize = 0;
        for (all_names) |name| {
            if (rand.boolean()) {
                modules[module_count] = name;
                module_count += 1;
            }
        }

        // Count expected mismatches: in exports but not in modules
        var expected_mismatches: usize = 0;
        for (exports[0..export_count]) |exp| {
            var found = false;
            for (modules[0..module_count]) |mod| {
                if (strEql(exp, mod)) {
                    found = true;
                    break;
                }
            }
            if (!found) expected_mismatches += 1;
        }

        var pkg = testManifest();
        pkg.platform = .any;
        pkg.system_libraries = &.{};
        pkg.exports = exports[0..export_count];

        const result = validate(&pkg, &.{}, &.{}, &.{}, modules[0..module_count]);

        var actual_mismatches: usize = 0;
        for (result.slice()) |err| {
            if (err.tag == .export_mismatch) actual_mismatches += 1;
        }

        if (actual_mismatches != expected_mismatches) {
            std.debug.print("Property 10 failed: {} exports, {} modules, expected {} mismatches, got {}\n", .{ export_count, module_count, expected_mismatches, actual_mismatches });
            return error.TestUnexpectedResult;
        }
    }
}

test "property: platform-library consistency — rejects invalid combos (randomized)" {
    // Property 11: For platform=.windows, only allowed Windows syslibs are
    // accepted. For platform=.any, system_libraries must be empty.
    // Generate random platform/syslib combos and verify the validator
    // catches all violations.
    //
    // Validates: Requirements 21.1, 21.2

    var prng = std.Random.DefaultPrng.init(0xD1A7_0011);
    const rand = prng.random();

    const win_allowed = [_][]const u8{ "kernel32", "gdi32", "user32", "shell32", "opengl32", "winhttp", "bcrypt", "ws2_32" };
    const non_win_libs = [_][]const u8{ "libcurl", "libssl", "libpng", "zlib", "libfoo" };

    const iterations = 300;
    for (0..iterations) |_| {
        const platform_choice = rand.intRangeAtMost(u32, 0, 1); // 0=windows, 1=any

        if (platform_choice == 0) {
            // Windows platform: pick a random mix of allowed + disallowed libs
            var libs: [8][]const u8 = undefined;
            var lib_count: usize = 0;
            var expected_violations: usize = 0;

            // Add some allowed libs
            for (win_allowed) |lib| {
                if (rand.intRangeAtMost(u32, 0, 2) == 0 and lib_count < 8) {
                    libs[lib_count] = lib;
                    lib_count += 1;
                }
            }
            // Add some disallowed libs
            for (non_win_libs) |lib| {
                if (rand.intRangeAtMost(u32, 0, 2) == 0 and lib_count < 8) {
                    libs[lib_count] = lib;
                    lib_count += 1;
                    expected_violations += 1;
                }
            }

            var pkg = testManifest();
            pkg.platform = .windows;
            pkg.system_libraries = libs[0..lib_count];
            pkg.exports = &.{};

            const result = validate(&pkg, &.{}, &.{}, &.{}, &.{});

            var actual_violations: usize = 0;
            for (result.slice()) |err| {
                if (err.tag == .platform_library_violation) actual_violations += 1;
            }

            if (actual_violations != expected_violations) {
                std.debug.print("Property 11 (windows) failed: {} libs, expected {} violations, got {}\n", .{ lib_count, expected_violations, actual_violations });
                return error.TestUnexpectedResult;
            }
        } else {
            // .any platform: any non-empty syslibs should trigger exactly 1 violation
            var libs: [4][]const u8 = undefined;
            var lib_count: usize = 0;
            const add_libs = rand.boolean();
            if (add_libs) {
                // Add 1-3 random libs
                const n = rand.intRangeAtMost(usize, 1, 3);
                for (0..n) |i| {
                    libs[i] = win_allowed[rand.intRangeLessThan(usize, 0, win_allowed.len)];
                    lib_count += 1;
                }
            }

            const expected: usize = if (lib_count > 0) 1 else 0;

            var pkg = testManifest();
            pkg.platform = .any;
            pkg.system_libraries = libs[0..lib_count];
            pkg.exports = &.{};

            const result = validate(&pkg, &.{}, &.{}, &.{}, &.{});

            var actual: usize = 0;
            for (result.slice()) |err| {
                if (err.tag == .platform_library_violation) actual += 1;
            }

            if (actual != expected) {
                std.debug.print("Property 11 (any) failed: {} libs, expected {} violations, got {}\n", .{ lib_count, expected, actual });
                return error.TestUnexpectedResult;
            }
        }
    }
}
