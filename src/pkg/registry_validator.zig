// Registry-side publish validation for the zpm package protocol.
//
// Validates packages submitted for publishing before they enter the registry.
// Uses a caller-supplied lookup function to check dependency existence,
// keeping this module pure and testable without a real registry.
//
// Requirements: 19.1, 19.2, 19.3, 19.4

const manifest = @import("manifest.zig");
const PackageManifest = manifest.PackageManifest;

// ── Error Types ──

pub const PublishErrorTag = enum {
    dependency_not_found,
    layer_violation,
    scope_mismatch,
};

pub const PublishError = struct {
    tag: PublishErrorTag,
    message: []const u8,
    detail: []const u8 = "",
};

const max_errors = 16;

pub const PublishResult = struct {
    errors: [max_errors]PublishError = undefined,
    count: usize = 0,
    /// HTTP-equivalent status: 200 on success, 400 on validation failure.
    status: u16 = 200,

    pub fn ok(self: *const PublishResult) bool {
        return self.count == 0;
    }

    pub fn add(self: *PublishResult, tag: PublishErrorTag, message: []const u8, detail: []const u8) void {
        if (self.count < max_errors) {
            self.errors[self.count] = .{ .tag = tag, .message = message, .detail = detail };
            self.count += 1;
        }
        self.status = 400;
    }

    pub fn slice(self: *const PublishResult) []const PublishError {
        return self.errors[0..self.count];
    }
};

// ── Dependency Lookup ──

/// Callback to check if a dependency exists in the registry.
/// Takes a scoped name (e.g. "@zpm/core") and returns the layer if found.
pub const DepLookupResult = union(enum) {
    found: u2, // layer of the dependency
    not_found: void,
};

pub const DepLookupFn = *const fn (scoped_name: []const u8) DepLookupResult;

// ── Validation ──

/// Validates a package manifest for registry publish acceptance.
///
/// Checks:
///   1. All zpm_dependencies exist in the registry (via lookup_fn)
///   2. Dependency graph satisfies layer ordering (dep.layer <= pkg.layer)
///   3. Scope matches the publisher's authorized scope
///
/// Parameters:
///   - pkg: The package manifest being published
///   - publisher_scope: The scope the publisher is authorized to publish under
///   - lookup_fn: Callback to check dependency existence and get layer info
pub fn validatePublish(
    pkg: *const PackageManifest,
    publisher_scope: []const u8,
    lookup_fn: DepLookupFn,
) PublishResult {
    var result = PublishResult{};

    // Rule 1: Scope must match publisher's authorized scope
    if (!strEql(pkg.scope, publisher_scope)) {
        result.add(
            .scope_mismatch,
            "package scope does not match publisher's authorized scope",
            pkg.scope,
        );
    }

    // Rule 2 & 3: All zpm_dependencies must exist and satisfy layer ordering
    for (pkg.zpm_dependencies) |dep_name| {
        const lookup = lookup_fn(dep_name);
        switch (lookup) {
            .not_found => {
                result.add(
                    .dependency_not_found,
                    "declared dependency does not exist in registry",
                    dep_name,
                );
            },
            .found => |dep_layer| {
                if (dep_layer > pkg.layer) {
                    result.add(
                        .layer_violation,
                        "dependency has higher layer than package",
                        dep_name,
                    );
                }
            },
        }
    }

    return result;
}

// ── Helpers ──

fn strEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (ca != cb) return false;
    }
    return true;
}

// ── Tests ──

const std = @import("std");
const testing = std.testing;

// ── Mock Lookup Functions ──

fn lookupAllExistLayer0(scoped_name: []const u8) DepLookupResult {
    _ = scoped_name;
    return .{ .found = 0 };
}

fn lookupNoneExist(scoped_name: []const u8) DepLookupResult {
    _ = scoped_name;
    return .{ .not_found = {} };
}

fn lookupMixed(scoped_name: []const u8) DepLookupResult {
    if (strEql(scoped_name, "@zpm/core")) return .{ .found = 0 };
    if (strEql(scoped_name, "@zpm/win32")) return .{ .found = 1 };
    if (strEql(scoped_name, "@zpm/primitives")) return .{ .found = 2 };
    return .{ .not_found = {} };
}

fn testManifest() PackageManifest {
    return .{
        .protocol_version = 1,
        .scope = "zpm",
        .name = "window",
        .version = "0.1.0",
        .layer = 1,
        .platform = .windows,
        .zpm_dependencies = &.{ "@zpm/core", "@zpm/win32" },
    };
}

// ── Scope Matching ──

test "validatePublish: matching scope passes" {
    const pkg = testManifest();
    const result = validatePublish(&pkg, "zpm", &lookupAllExistLayer0);
    // win32 at layer 0 <= pkg layer 1, core at layer 0 <= 1 — all good
    try testing.expect(result.ok());
    try testing.expectEqual(@as(u16, 200), result.status);
}

test "validatePublish: mismatched scope rejected" {
    const pkg = testManifest(); // scope = "zpm"
    const result = validatePublish(&pkg, "other-org", &lookupAllExistLayer0);
    try testing.expect(!result.ok());
    try testing.expectEqual(@as(u16, 400), result.status);
    try testing.expectEqual(PublishErrorTag.scope_mismatch, result.slice()[0].tag);
}

// ── Dependency Existence ──

test "validatePublish: all deps exist passes" {
    var pkg = testManifest();
    pkg.zpm_dependencies = &.{"@zpm/core"};
    const result = validatePublish(&pkg, "zpm", &lookupAllExistLayer0);
    try testing.expect(result.ok());
}

test "validatePublish: missing dep rejected" {
    var pkg = testManifest();
    pkg.zpm_dependencies = &.{"@zpm/nonexistent"};
    const result = validatePublish(&pkg, "zpm", &lookupNoneExist);
    try testing.expect(!result.ok());
    try testing.expectEqual(PublishErrorTag.dependency_not_found, result.slice()[0].tag);
    try testing.expectEqualStrings("@zpm/nonexistent", result.slice()[0].detail);
}

test "validatePublish: multiple missing deps all reported" {
    var pkg = testManifest();
    pkg.zpm_dependencies = &.{ "@zpm/foo", "@zpm/bar" };
    const result = validatePublish(&pkg, "zpm", &lookupNoneExist);
    try testing.expectEqual(@as(usize, 2), result.count);
    for (result.slice()) |err| {
        try testing.expectEqual(PublishErrorTag.dependency_not_found, err.tag);
    }
}

// ── Layer Ordering ──

test "validatePublish: dep at higher layer rejected" {
    var pkg = testManifest();
    pkg.layer = 0; // layer 0 package
    pkg.zpm_dependencies = &.{"@zpm/win32"}; // win32 is layer 1
    const result = validatePublish(&pkg, "zpm", &lookupMixed);
    try testing.expect(!result.ok());
    var found_layer_violation = false;
    for (result.slice()) |err| {
        if (err.tag == .layer_violation) found_layer_violation = true;
    }
    try testing.expect(found_layer_violation);
}

test "validatePublish: dep at equal layer passes" {
    var pkg = testManifest();
    pkg.layer = 1;
    pkg.zpm_dependencies = &.{"@zpm/win32"}; // win32 is layer 1
    const result = validatePublish(&pkg, "zpm", &lookupMixed);
    try testing.expect(result.ok());
}

test "validatePublish: dep at lower layer passes" {
    var pkg = testManifest();
    pkg.layer = 2;
    pkg.zpm_dependencies = &.{ "@zpm/core", "@zpm/win32" }; // layers 0, 1
    const result = validatePublish(&pkg, "zpm", &lookupMixed);
    try testing.expect(result.ok());
}

// ── No Dependencies ──

test "validatePublish: no deps passes" {
    var pkg = testManifest();
    pkg.zpm_dependencies = &.{};
    const result = validatePublish(&pkg, "zpm", &lookupNoneExist);
    try testing.expect(result.ok());
}

// ── Combined Errors ──

test "validatePublish: scope mismatch + missing dep + layer violation all reported" {
    var pkg = testManifest();
    pkg.scope = "wrong-org";
    pkg.layer = 0;
    pkg.zpm_dependencies = &.{ "@zpm/nonexistent", "@zpm/win32" };
    const result = validatePublish(&pkg, "zpm", &lookupMixed);
    try testing.expect(!result.ok());
    // Should have: scope_mismatch, dependency_not_found, layer_violation
    var has_scope = false;
    var has_dep = false;
    var has_layer = false;
    for (result.slice()) |err| {
        if (err.tag == .scope_mismatch) has_scope = true;
        if (err.tag == .dependency_not_found) has_dep = true;
        if (err.tag == .layer_violation) has_layer = true;
    }
    try testing.expect(has_scope);
    try testing.expect(has_dep);
    try testing.expect(has_layer);
    try testing.expectEqual(@as(u16, 400), result.status);
}

// ── Property Tests ──

// Thread-local state for the randomized lookup function
var prop19_existing_deps: [16][]const u8 = undefined;
var prop19_existing_count: usize = 0;

fn lookupProp19(scoped_name: []const u8) DepLookupResult {
    for (prop19_existing_deps[0..prop19_existing_count]) |existing| {
        if (strEql(scoped_name, existing)) return .{ .found = 0 };
    }
    return .{ .not_found = {} };
}

test "property: registry publish dependency existence — non-existent deps rejected (randomized)" {
    // Property 19: Submit packages with non-existent deps via validatePublish,
    // verify registry rejects with dependency_not_found error.
    //
    // **Validates: Requirement 19.1**

    var prng = std.Random.DefaultPrng.init(0xBAAD_CAFE);
    const rand = prng.random();

    // Pool of possible dependency names
    const dep_pool = [_][]const u8{
        "@zpm/core",
        "@zpm/window",
        "@zpm/gl",
        "@zpm/timer",
        "@zpm/input",
        "@zpm/http",
        "@zpm/crypto",
        "@zpm/text",
        "@zpm/color",
        "@zpm/png",
        "@zpm/mcp",
        "@zpm/seqlock",
        "@zpm/logging",
        "@zpm/threading",
        "@zpm/file-io",
        "@zpm/win32",
    };

    const iterations = 200;
    for (0..iterations) |_| {
        // Randomly select which deps "exist" in the registry (0 to 8)
        const num_existing = rand.intRangeAtMost(usize, 0, 8);
        prop19_existing_count = 0;

        // Pick unique existing deps
        var used: [16]bool = .{false} ** 16;
        for (0..num_existing) |_| {
            var idx = rand.intRangeLessThan(usize, 0, dep_pool.len);
            // Find next unused slot
            var attempts: usize = 0;
            while (used[idx] and attempts < dep_pool.len) {
                idx = (idx + 1) % dep_pool.len;
                attempts += 1;
            }
            if (!used[idx]) {
                used[idx] = true;
                prop19_existing_deps[prop19_existing_count] = dep_pool[idx];
                prop19_existing_count += 1;
            }
        }

        // Build a dep list that includes at least one non-existing dep
        var dep_list: [8][]const u8 = undefined;
        var dep_count: usize = 0;
        var has_nonexistent = false;

        const num_deps = rand.intRangeAtMost(usize, 1, 8);
        for (0..num_deps) |_| {
            const dep = dep_pool[rand.intRangeLessThan(usize, 0, dep_pool.len)];
            // Avoid duplicates in dep_list
            var dup = false;
            for (dep_list[0..dep_count]) |existing| {
                if (strEql(existing, dep)) {
                    dup = true;
                    break;
                }
            }
            if (dup) continue;

            dep_list[dep_count] = dep;
            dep_count += 1;

            // Check if this dep is non-existent
            var found = false;
            for (prop19_existing_deps[0..prop19_existing_count]) |existing| {
                if (strEql(dep, existing)) {
                    found = true;
                    break;
                }
            }
            if (!found) has_nonexistent = true;
        }

        // If we didn't get any non-existent deps, force one
        if (!has_nonexistent and dep_count < 8) {
            // Find a dep not in the existing set
            for (dep_pool) |dep| {
                var found = false;
                for (prop19_existing_deps[0..prop19_existing_count]) |existing| {
                    if (strEql(dep, existing)) {
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    // Also check not already in dep_list
                    var dup = false;
                    for (dep_list[0..dep_count]) |d| {
                        if (strEql(d, dep)) {
                            dup = true;
                            break;
                        }
                    }
                    if (!dup) {
                        dep_list[dep_count] = dep;
                        dep_count += 1;
                        has_nonexistent = true;
                        break;
                    }
                }
            }
        }

        // If all deps exist (entire pool is existing), skip this iteration
        if (!has_nonexistent) continue;

        const deps_slice = dep_list[0..dep_count];

        var pkg = PackageManifest{
            .protocol_version = 1,
            .scope = "zpm",
            .name = "test-pkg",
            .version = "0.1.0",
            .layer = 2, // layer 2 so layer violations don't interfere
            .platform = .any,
            .zpm_dependencies = deps_slice,
        };
        _ = &pkg;

        const result = validatePublish(&pkg, "zpm", &lookupProp19);

        // Must not be ok — at least one dependency_not_found error
        if (result.ok()) {
            std.debug.print("Property 19 failed: validatePublish accepted package with non-existent deps\n", .{});
            std.debug.print("  existing deps in registry: {}\n", .{prop19_existing_count});
            for (prop19_existing_deps[0..prop19_existing_count]) |e| {
                std.debug.print("    {s}\n", .{e});
            }
            std.debug.print("  package deps:\n", .{});
            for (deps_slice) |d| {
                std.debug.print("    {s}\n", .{d});
            }
            return error.TestUnexpectedResult;
        }

        // Verify at least one dependency_not_found error exists
        var found_dep_not_found = false;
        for (result.slice()) |err| {
            if (err.tag == .dependency_not_found) {
                found_dep_not_found = true;
                // Verify the detail is actually a non-existent dep
                var is_missing = true;
                for (prop19_existing_deps[0..prop19_existing_count]) |existing| {
                    if (strEql(err.detail, existing)) {
                        is_missing = false;
                        break;
                    }
                }
                try testing.expect(is_missing);
            }
        }
        try testing.expect(found_dep_not_found);
    }
}
