// Registry version store for the zpm package protocol.
//
// Manages published package version metadata with immutability guarantees
// and version yanking. Uses a vtable for storage operations so the core
// logic is testable without a real database.
//
// Requirements: 20.1, 20.2, 20.3

const std = @import("std");

// ── Public Types ──

pub const VersionMetadata = struct {
    scope: []const u8,
    name: []const u8,
    version: []const u8,
    url: []const u8,
    hash: []const u8,
    layer: u2,
    system_libraries: []const []const u8,
    zpm_dependencies: []const []const u8,
    constraints_no_allocator: bool,
    constraints_no_std_io: bool,
    published_at: i64,
    yanked: bool,
};

pub const StoreError = error{
    VersionAlreadyExists,
    VersionNotFound,
    StorageFailure,
};

pub const StoreResult = union(enum) {
    ok: VersionMetadata,
    err: StoreError,
};

// ── Storage Vtable ──

pub const StorageVtable = struct {
    /// Store version metadata. Returns false if storage fails.
    put: *const fn (scope: []const u8, name: []const u8, version: []const u8, meta: *const VersionMetadata) bool,
    /// Get version metadata by exact version. Returns null if not found.
    get: *const fn (scope: []const u8, name: []const u8, version: []const u8) ?*const VersionMetadata,
    /// Get all versions for a package. Returns slice of pointers.
    list: *const fn (scope: []const u8, name: []const u8, buf: []*const VersionMetadata) usize,
    /// Update yanked status. Returns false if version not found.
    set_yanked: *const fn (scope: []const u8, name: []const u8, version: []const u8, yanked: bool) bool,
};

// ── Version Store ──

pub const VersionStore = struct {
    vtable: StorageVtable,

    /// Publish a new version. Rejects if the version already exists (immutability).
    /// Requirements: 20.1
    pub fn publish(self: *const VersionStore, meta: *const VersionMetadata) StoreError!void {
        // Check if version already exists — reject to enforce immutability
        if (self.vtable.get(meta.scope, meta.name, meta.version) != null) {
            return error.VersionAlreadyExists;
        }

        if (!self.vtable.put(meta.scope, meta.name, meta.version, meta)) {
            return error.StorageFailure;
        }
    }

    /// Get version metadata by exact version. Returns yanked versions too.
    /// Requirements: 20.3
    pub fn getVersion(
        self: *const VersionStore,
        scope: []const u8,
        name: []const u8,
        version: []const u8,
    ) StoreError!*const VersionMetadata {
        return self.vtable.get(scope, name, version) orelse error.VersionNotFound;
    }

    /// Mark a version as yanked. Yanked versions are excluded from resolveLatest
    /// but still returned by getVersion for reproducibility.
    /// Requirements: 20.2
    pub fn yank(
        self: *const VersionStore,
        scope: []const u8,
        name: []const u8,
        version: []const u8,
    ) StoreError!void {
        if (!self.vtable.set_yanked(scope, name, version, true)) {
            return error.VersionNotFound;
        }
    }

    /// Resolve the latest non-yanked version for a package.
    /// Returns VersionNotFound if no non-yanked versions exist.
    /// Requirements: 20.2
    pub fn resolveLatest(
        self: *const VersionStore,
        scope: []const u8,
        name: []const u8,
    ) StoreError!*const VersionMetadata {
        var buf: [64]*const VersionMetadata = undefined;
        const count = self.vtable.list(scope, name, &buf);

        if (count == 0) return error.VersionNotFound;

        // Find latest non-yanked version by published_at timestamp
        var best: ?*const VersionMetadata = null;
        for (buf[0..count]) |meta| {
            if (meta.yanked) continue;
            if (best == null or meta.published_at > best.?.published_at) {
                best = meta;
            }
        }

        return best orelse error.VersionNotFound;
    }
};

// ── Tests ──

const testing = std.testing;

// ── In-Memory Mock Storage ──

const max_stored = 32;

var stored_versions: [max_stored]VersionMetadata = undefined;
var stored_count: usize = 0;

fn resetStore() void {
    stored_count = 0;
}

fn mockPut(_: []const u8, _: []const u8, _: []const u8, meta: *const VersionMetadata) bool {
    if (stored_count >= max_stored) return false;
    stored_versions[stored_count] = meta.*;
    stored_count += 1;
    return true;
}

fn mockGet(scope: []const u8, name: []const u8, version: []const u8) ?*const VersionMetadata {
    for (stored_versions[0..stored_count]) |*v| {
        if (strEql(v.scope, scope) and strEql(v.name, name) and strEql(v.version, version)) {
            return v;
        }
    }
    return null;
}

fn mockList(scope: []const u8, name: []const u8, buf: []*const VersionMetadata) usize {
    var count: usize = 0;
    for (stored_versions[0..stored_count]) |*v| {
        if (strEql(v.scope, scope) and strEql(v.name, name)) {
            if (count < buf.len) {
                buf[count] = v;
                count += 1;
            }
        }
    }
    return count;
}

fn mockSetYanked(scope: []const u8, name: []const u8, version: []const u8, yanked: bool) bool {
    for (stored_versions[0..stored_count]) |*v| {
        if (strEql(v.scope, scope) and strEql(v.name, name) and strEql(v.version, version)) {
            v.yanked = yanked;
            return true;
        }
    }
    return false;
}

fn strEql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

const mock_vtable = StorageVtable{
    .put = &mockPut,
    .get = &mockGet,
    .list = &mockList,
    .set_yanked = &mockSetYanked,
};

fn testStore() VersionStore {
    return .{ .vtable = mock_vtable };
}

fn testMeta(version: []const u8, ts: i64) VersionMetadata {
    return .{
        .scope = "zpm",
        .name = "core",
        .version = version,
        .url = "https://example.com/core.tar.gz",
        .hash = "1220abc",
        .layer = 0,
        .system_libraries = &.{},
        .zpm_dependencies = &.{},
        .constraints_no_allocator = false,
        .constraints_no_std_io = false,
        .published_at = ts,
        .yanked = false,
    };
}

// ── Publish Tests ──

test "publish: stores new version" {
    resetStore();
    const store = testStore();
    const meta = testMeta("0.1.0", 1000);
    try store.publish(&meta);

    const got = try store.getVersion("zpm", "core", "0.1.0");
    try testing.expectEqualStrings("0.1.0", got.version);
    try testing.expectEqual(@as(i64, 1000), got.published_at);
}

test "publish: rejects duplicate version (immutability)" {
    resetStore();
    const store = testStore();
    const meta = testMeta("0.1.0", 1000);
    try store.publish(&meta);

    // Second publish of same version should fail
    try testing.expectError(error.VersionAlreadyExists, store.publish(&meta));
}

test "publish: different versions of same package allowed" {
    resetStore();
    const store = testStore();
    const v1 = testMeta("0.1.0", 1000);
    const v2 = testMeta("0.2.0", 2000);
    try store.publish(&v1);
    try store.publish(&v2);

    const got1 = try store.getVersion("zpm", "core", "0.1.0");
    try testing.expectEqualStrings("0.1.0", got1.version);
    const got2 = try store.getVersion("zpm", "core", "0.2.0");
    try testing.expectEqualStrings("0.2.0", got2.version);
}

// ── GetVersion Tests ──

test "getVersion: returns metadata for existing version" {
    resetStore();
    const store = testStore();
    const meta = testMeta("0.1.0", 1000);
    try store.publish(&meta);

    const got = try store.getVersion("zpm", "core", "0.1.0");
    try testing.expectEqualStrings("zpm", got.scope);
    try testing.expectEqualStrings("core", got.name);
    try testing.expectEqualStrings("0.1.0", got.version);
}

test "getVersion: returns VersionNotFound for missing version" {
    resetStore();
    const store = testStore();
    try testing.expectError(error.VersionNotFound, store.getVersion("zpm", "core", "9.9.9"));
}

test "getVersion: returns yanked versions (reproducibility)" {
    resetStore();
    const store = testStore();
    const meta = testMeta("0.1.0", 1000);
    try store.publish(&meta);
    try store.yank("zpm", "core", "0.1.0");

    // getVersion should still return yanked versions
    const got = try store.getVersion("zpm", "core", "0.1.0");
    try testing.expectEqualStrings("0.1.0", got.version);
    try testing.expect(got.yanked);
}

// ── Yank Tests ──

test "yank: marks version as yanked" {
    resetStore();
    const store = testStore();
    const meta = testMeta("0.1.0", 1000);
    try store.publish(&meta);

    try store.yank("zpm", "core", "0.1.0");

    const got = try store.getVersion("zpm", "core", "0.1.0");
    try testing.expect(got.yanked);
}

test "yank: returns VersionNotFound for missing version" {
    resetStore();
    const store = testStore();
    try testing.expectError(error.VersionNotFound, store.yank("zpm", "core", "9.9.9"));
}

// ── ResolveLatest Tests ──

test "resolveLatest: returns latest non-yanked version" {
    resetStore();
    const store = testStore();
    const v1 = testMeta("0.1.0", 1000);
    const v2 = testMeta("0.2.0", 2000);
    const v3 = testMeta("0.3.0", 3000);
    try store.publish(&v1);
    try store.publish(&v2);
    try store.publish(&v3);

    const latest = try store.resolveLatest("zpm", "core");
    try testing.expectEqualStrings("0.3.0", latest.version);
}

test "resolveLatest: skips yanked versions" {
    resetStore();
    const store = testStore();
    const v1 = testMeta("0.1.0", 1000);
    const v2 = testMeta("0.2.0", 2000);
    try store.publish(&v1);
    try store.publish(&v2);

    // Yank the latest
    try store.yank("zpm", "core", "0.2.0");

    const latest = try store.resolveLatest("zpm", "core");
    try testing.expectEqualStrings("0.1.0", latest.version);
}

test "resolveLatest: all yanked returns VersionNotFound" {
    resetStore();
    const store = testStore();
    const v1 = testMeta("0.1.0", 1000);
    try store.publish(&v1);
    try store.yank("zpm", "core", "0.1.0");

    try testing.expectError(error.VersionNotFound, store.resolveLatest("zpm", "core"));
}

test "resolveLatest: no versions returns VersionNotFound" {
    resetStore();
    const store = testStore();
    try testing.expectError(error.VersionNotFound, store.resolveLatest("zpm", "core"));
}

// ── Immutability Tests ──

test "published metadata is immutable — fields unchanged after publish" {
    resetStore();
    const store = testStore();
    const meta = testMeta("0.1.0", 1000);
    try store.publish(&meta);

    const got = try store.getVersion("zpm", "core", "0.1.0");
    try testing.expectEqualStrings("https://example.com/core.tar.gz", got.url);
    try testing.expectEqualStrings("1220abc", got.hash);
    try testing.expectEqual(@as(u2, 0), got.layer);
    try testing.expect(!got.constraints_no_allocator);
    try testing.expect(!got.constraints_no_std_io);
    try testing.expectEqual(@as(i64, 1000), got.published_at);
}

// ── Property Tests ──

test "property: version immutability — metadata unchanged across reads (randomized)" {
    // Property 13: Publish a version, read metadata multiple times,
    // verify all fields are identical every time.
    //
    // **Validates: Requirements 20.1**

    var prng = std.Random.DefaultPrng.init(0xDEAD_BEEF);
    const rand = prng.random();

    const scopes = [_][]const u8{ "zpm", "myorg", "acme", "test-scope" };
    const pkg_names = [_][]const u8{ "core", "window", "gl-app", "utils" };
    const versions = [_][]const u8{ "0.1.0", "1.0.0", "2.3.4", "0.0.1", "10.20.30" };
    const urls = [_][]const u8{
        "https://example.com/a.tar.gz",
        "https://registry.zpm.dev/pkg/b.tar.gz",
        "https://cdn.example.org/c.tar.gz",
    };
    const hashes = [_][]const u8{ "1220abc", "1220def", "1220999", "1220000" };

    const iterations = 200;
    for (0..iterations) |_| {
        resetStore();
        const store = testStore();

        const scope = scopes[rand.intRangeLessThan(usize, 0, scopes.len)];
        const pkg_name = pkg_names[rand.intRangeLessThan(usize, 0, pkg_names.len)];
        const version = versions[rand.intRangeLessThan(usize, 0, versions.len)];
        const url = urls[rand.intRangeLessThan(usize, 0, urls.len)];
        const hash = hashes[rand.intRangeLessThan(usize, 0, hashes.len)];
        const layer: u2 = @intCast(rand.intRangeAtMost(u32, 0, 2));
        const no_alloc = rand.boolean();
        const no_io = rand.boolean();
        const ts = rand.intRangeAtMost(i64, 1000, 999999);

        const meta = VersionMetadata{
            .scope = scope,
            .name = pkg_name,
            .version = version,
            .url = url,
            .hash = hash,
            .layer = layer,
            .system_libraries = &.{},
            .zpm_dependencies = &.{},
            .constraints_no_allocator = no_alloc,
            .constraints_no_std_io = no_io,
            .published_at = ts,
            .yanked = false,
        };

        try store.publish(&meta);

        // Read multiple times and verify all fields are identical
        const read_count = rand.intRangeAtMost(usize, 2, 10);
        for (0..read_count) |_| {
            const got = try store.getVersion(scope, pkg_name, version);
            try testing.expectEqualStrings(scope, got.scope);
            try testing.expectEqualStrings(pkg_name, got.name);
            try testing.expectEqualStrings(version, got.version);
            try testing.expectEqualStrings(url, got.url);
            try testing.expectEqualStrings(hash, got.hash);
            try testing.expectEqual(layer, got.layer);
            try testing.expectEqual(no_alloc, got.constraints_no_allocator);
            try testing.expectEqual(no_io, got.constraints_no_std_io);
            try testing.expectEqual(ts, got.published_at);
            try testing.expect(!got.yanked);
        }
    }
}

test "property: yanked version exclusion — excluded from resolveLatest, returned by getVersion (randomized)" {
    // Property 14: Publish multiple versions, yank some, verify yanked
    // versions are excluded from resolveLatest but still returned by getVersion.
    //
    // **Validates: Requirements 20.2, 20.3**

    var prng = std.Random.DefaultPrng.init(0xCAFE_F00D);
    const rand = prng.random();

    const iterations = 200;
    for (0..iterations) |_| {
        resetStore();
        const store = testStore();

        // Publish 2-5 versions with increasing timestamps
        const num_versions = rand.intRangeAtMost(usize, 2, 5);
        var ver_bufs: [5][8]u8 = undefined;
        var ver_slices: [5][]const u8 = undefined;
        var yanked_flags: [5]bool = undefined;
        var any_not_yanked = false;

        for (0..num_versions) |vi| {
            const ver_len = std.fmt.bufPrint(&ver_bufs[vi], "0.{}.0", .{vi + 1}) catch unreachable;
            ver_slices[vi] = ver_len;

            const meta = VersionMetadata{
                .scope = "zpm",
                .name = "core",
                .version = ver_len,
                .url = "https://example.com/pkg.tar.gz",
                .hash = "1220abc",
                .layer = 0,
                .system_libraries = &.{},
                .zpm_dependencies = &.{},
                .constraints_no_allocator = false,
                .constraints_no_std_io = false,
                .published_at = @as(i64, @intCast(vi + 1)) * 1000,
                .yanked = false,
            };
            try store.publish(&meta);

            // Randomly decide to yank this version
            yanked_flags[vi] = rand.boolean();
            if (!yanked_flags[vi]) any_not_yanked = true;
        }

        // Ensure at least one version is not yanked for a meaningful test
        // (if all are yanked, un-yank the last one)
        if (!any_not_yanked) {
            yanked_flags[num_versions - 1] = false;
        }

        // Apply yank decisions
        for (0..num_versions) |vi| {
            if (yanked_flags[vi]) {
                try store.yank("zpm", "core", ver_slices[vi]);
            }
        }

        // Verify: yanked versions still returned by getVersion
        for (0..num_versions) |vi| {
            const got = try store.getVersion("zpm", "core", ver_slices[vi]);
            try testing.expectEqualStrings(ver_slices[vi], got.version);
            if (yanked_flags[vi]) {
                try testing.expect(got.yanked);
            }
        }

        // Verify: resolveLatest returns a non-yanked version
        const latest = try store.resolveLatest("zpm", "core");
        try testing.expect(!latest.yanked);

        // Verify: the resolved latest is actually the highest-timestamp non-yanked version
        var expected_best_ts: i64 = 0;
        var expected_best_ver: []const u8 = "";
        for (0..num_versions) |vi| {
            if (!yanked_flags[vi]) {
                const ts = @as(i64, @intCast(vi + 1)) * 1000;
                if (ts > expected_best_ts) {
                    expected_best_ts = ts;
                    expected_best_ver = ver_slices[vi];
                }
            }
        }
        try testing.expectEqualStrings(expected_best_ver, latest.version);
    }
}
