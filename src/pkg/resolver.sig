// Dependency resolver for the zpm package protocol.
// Zero allocator — uses static arrays with linear scan for dedup.

pub const ResolveError = error{ LayerViolation, CircularDependency, FetchFailed, TooManyPackages };

pub const ResolvedDep = struct {
    scope: []const u8,
    name: []const u8,
    version: []const u8,
    url: []const u8,
    hash: []const u8,
    layer: u2,
    system_libraries: []const []const u8,
    zpm_dependencies: []const []const u8,
    is_direct: bool,
};

pub const FetchResult = union(enum) { ok: ResolvedDep, err: ResolveError };
pub const FetchFn = *const fn (scoped_name: []const u8) FetchResult;
pub const ResolvedGraph = struct {
    direct: []const ResolvedDep,
    transitive: []const ResolvedDep,
    system_libraries: []const []const u8,
};

const max_packages = 256;
const max_syslibs = 64;

fn strEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| { if (ca != cb) return false; }
    return true;
}
fn containsStr(list: []const []const u8, needle: []const u8) bool {
    for (list) |item| { if (strEql(item, needle)) return true; }
    return false;
}

var resolved_buf: [max_packages]ResolvedDep = undefined;
var resolved_names: [max_packages][]const u8 = undefined;
var resolved_count: usize = 0;
var direct_buf: [max_packages]ResolvedDep = undefined;
var direct_count: usize = 0;
var transitive_buf: [max_packages]ResolvedDep = undefined;
var transitive_count: usize = 0;
var syslib_buf: [max_syslibs][]const u8 = undefined;
var syslib_count: usize = 0;

pub fn resolve(requested: []const []const u8, fetch: FetchFn) ResolveError!ResolvedGraph {
    resolved_count = 0; direct_count = 0; transitive_count = 0; syslib_count = 0;
    var queue_buf: [max_packages][]const u8 = undefined;
    var queue_len: usize = 0;
    var queue_head: usize = 0;
    for (requested) |pkg| {
        if (queue_len >= max_packages) return error.TooManyPackages;
        queue_buf[queue_len] = pkg; queue_len += 1;
    }
    while (queue_head < queue_len) {
        const scoped_name = queue_buf[queue_head]; queue_head += 1;
        if (containsStr(resolved_names[0..resolved_count], scoped_name)) continue;
        if (resolved_count >= max_packages) return error.TooManyPackages;
        var dep = switch (fetch(scoped_name)) { .ok => |d| d, .err => |e| return e };
        dep.is_direct = containsStr(requested, scoped_name);
        resolved_names[resolved_count] = scoped_name;
        resolved_buf[resolved_count] = dep;
        resolved_count += 1;
        for (dep.zpm_dependencies) |child_name| {
            if (!containsStr(resolved_names[0..resolved_count], child_name)) {
                if (queue_len >= max_packages) return error.TooManyPackages;
                queue_buf[queue_len] = child_name; queue_len += 1;
            }
        }
    }
    for (0..resolved_count) |i| {
        for (resolved_buf[i].zpm_dependencies) |child_name| {
            for (0..resolved_count) |j| {
                if (strEql(resolved_names[j], child_name) and resolved_buf[j].layer > resolved_buf[i].layer)
                    return error.LayerViolation;
            }
        }
    }
    try detectCycles();
    return buildGraph(requested);
}

fn detectCycles() ResolveError!void {
    var in_degree: [max_packages]usize = undefined;
    for (0..resolved_count) |i| in_degree[i] = 0;
    for (0..resolved_count) |i| {
        for (resolved_buf[i].zpm_dependencies) |child_name| {
            for (0..resolved_count) |j| {
                if (strEql(resolved_names[j], child_name)) in_degree[j] += 1;
            }
        }
    }
    var q_buf: [max_packages]usize = undefined;
    var q_len: usize = 0;
    var q_head: usize = 0;
    for (0..resolved_count) |i| {
        if (in_degree[i] == 0) { q_buf[q_len] = i; q_len += 1; }
    }
    var consumed: usize = 0;
    while (q_head < q_len) {
        const node_idx = q_buf[q_head]; q_head += 1; consumed += 1;
        for (resolved_buf[node_idx].zpm_dependencies) |child_name| {
            for (0..resolved_count) |j| {
                if (strEql(resolved_names[j], child_name)) {
                    in_degree[j] -= 1;
                    if (in_degree[j] == 0) { q_buf[q_len] = j; q_len += 1; }
                }
            }
        }
    }
    if (consumed != resolved_count) return error.CircularDependency;
}

fn buildGraph(requested: []const []const u8) ResolvedGraph {
    direct_count = 0; transitive_count = 0; syslib_count = 0;
    for (0..resolved_count) |i| {
        const dep = resolved_buf[i];
        for (dep.system_libraries) |lib| {
            if (!containsStr(syslib_buf[0..syslib_count], lib) and syslib_count < max_syslibs) {
                syslib_buf[syslib_count] = lib; syslib_count += 1;
            }
        }
        if (containsStr(requested, resolved_names[i])) {
            if (direct_count < max_packages) { direct_buf[direct_count] = dep; direct_count += 1; }
        } else {
            if (transitive_count < max_packages) { transitive_buf[transitive_count] = dep; transitive_count += 1; }
        }
    }
    return .{ .direct = direct_buf[0..direct_count], .transitive = transitive_buf[0..transitive_count], .system_libraries = syslib_buf[0..syslib_count] };
}
// ── Tests ──
const std = @import("std");
const testing = std.testing;
fn containsDep(deps: []const ResolvedDep, name: []const u8) bool {
    for (deps) |d| { if (strEql(d.name, name)) return true; } return false;
}
fn fetchSingleCore(sn: []const u8) FetchResult {
    if (strEql(sn, "@zpm/core")) return .{ .ok = .{ .scope = "zpm", .name = "core", .version = "0.1.0", .url = "https://registry.zpm.dev/pkg/@zpm/core/0.1.0.tar.gz", .hash = "1220abc123", .layer = 0, .system_libraries = &.{}, .zpm_dependencies = &.{}, .is_direct = false } };
    return .{ .err = error.FetchFailed };
}
fn fetchWindowGraph(sn: []const u8) FetchResult {
    if (strEql(sn, "@zpm/window")) return .{ .ok = .{ .scope = "zpm", .name = "window", .version = "0.1.0", .url = "url-w", .hash = "1220win", .layer = 1, .system_libraries = &.{ "kernel32", "gdi32", "user32", "shell32" }, .zpm_dependencies = &.{ "@zpm/win32", "@zpm/gl" }, .is_direct = false } };
    if (strEql(sn, "@zpm/win32")) return .{ .ok = .{ .scope = "zpm", .name = "win32", .version = "0.1.0", .url = "url-w32", .hash = "1220w32", .layer = 1, .system_libraries = &.{"kernel32"}, .zpm_dependencies = &.{}, .is_direct = false } };
    if (strEql(sn, "@zpm/gl")) return .{ .ok = .{ .scope = "zpm", .name = "gl", .version = "0.1.0", .url = "url-gl", .hash = "1220gl", .layer = 1, .system_libraries = &.{"opengl32"}, .zpm_dependencies = &.{}, .is_direct = false } };
    return .{ .err = error.FetchFailed };
}
fn fetchLayerViolation(sn: []const u8) FetchResult {
    if (strEql(sn, "@zpm/core")) return .{ .ok = .{ .scope = "zpm", .name = "core", .version = "0.1.0", .url = "u", .hash = "h", .layer = 0, .system_libraries = &.{}, .zpm_dependencies = &.{"@zpm/win32"}, .is_direct = false } };
    if (strEql(sn, "@zpm/win32")) return .{ .ok = .{ .scope = "zpm", .name = "win32", .version = "0.1.0", .url = "u", .hash = "h", .layer = 1, .system_libraries = &.{}, .zpm_dependencies = &.{}, .is_direct = false } };
    return .{ .err = error.FetchFailed };
}
fn fetchCycle(sn: []const u8) FetchResult {
    if (strEql(sn, "@pkg/a")) return .{ .ok = .{ .scope = "pkg", .name = "a", .version = "1.0.0", .url = "u", .hash = "h", .layer = 2, .system_libraries = &.{}, .zpm_dependencies = &.{"@pkg/b"}, .is_direct = false } };
    if (strEql(sn, "@pkg/b")) return .{ .ok = .{ .scope = "pkg", .name = "b", .version = "1.0.0", .url = "u", .hash = "h", .layer = 2, .system_libraries = &.{}, .zpm_dependencies = &.{"@pkg/c"}, .is_direct = false } };
    if (strEql(sn, "@pkg/c")) return .{ .ok = .{ .scope = "pkg", .name = "c", .version = "1.0.0", .url = "u", .hash = "h", .layer = 2, .system_libraries = &.{}, .zpm_dependencies = &.{"@pkg/a"}, .is_direct = false } };
    return .{ .err = error.FetchFailed };
}
fn fetchDiamond(sn: []const u8) FetchResult {
    if (strEql(sn, "@zpm/app")) return .{ .ok = .{ .scope = "zpm", .name = "app", .version = "0.1.0", .url = "u", .hash = "h", .layer = 2, .system_libraries = &.{}, .zpm_dependencies = &.{ "@zpm/window", "@zpm/timer" }, .is_direct = false } };
    if (strEql(sn, "@zpm/window")) return .{ .ok = .{ .scope = "zpm", .name = "window", .version = "0.1.0", .url = "u", .hash = "h", .layer = 1, .system_libraries = &.{ "kernel32", "gdi32" }, .zpm_dependencies = &.{"@zpm/win32"}, .is_direct = false } };
    if (strEql(sn, "@zpm/timer")) return .{ .ok = .{ .scope = "zpm", .name = "timer", .version = "0.1.0", .url = "u", .hash = "h", .layer = 1, .system_libraries = &.{"kernel32"}, .zpm_dependencies = &.{"@zpm/win32"}, .is_direct = false } };
    if (strEql(sn, "@zpm/win32")) return .{ .ok = .{ .scope = "zpm", .name = "win32", .version = "0.1.0", .url = "u", .hash = "h", .layer = 1, .system_libraries = &.{"kernel32"}, .zpm_dependencies = &.{}, .is_direct = false } };
    return .{ .err = error.FetchFailed };
}
fn fetchAlwaysFails(_: []const u8) FetchResult { return .{ .err = error.FetchFailed }; }

test "resolve: single package" { const g = try resolve(&.{"@zpm/core"}, &fetchSingleCore); try testing.expectEqual(@as(usize, 1), g.direct.len); try testing.expectEqual(@as(usize, 0), g.transitive.len); try testing.expect(g.direct[0].is_direct); }
test "resolve: transitive deps" { const g = try resolve(&.{"@zpm/window"}, &fetchWindowGraph); try testing.expectEqual(@as(usize, 1), g.direct.len); try testing.expectEqual(@as(usize, 2), g.transitive.len); }
test "resolve: dedup" { const g = try resolve(&.{ "@zpm/window", "@zpm/win32" }, &fetchWindowGraph); try testing.expectEqual(@as(usize, 3), g.direct.len + g.transitive.len); }
test "resolve: layer violation" { try testing.expectError(error.LayerViolation, resolve(&.{"@zpm/core"}, &fetchLayerViolation)); }
test "resolve: cycle" { try testing.expectError(error.CircularDependency, resolve(&.{"@pkg/a"}, &fetchCycle)); }
test "resolve: syslib dedup" { const g = try resolve(&.{"@zpm/app"}, &fetchDiamond); try testing.expectEqual(@as(usize, 2), g.system_libraries.len); }
test "resolve: direct marking" { const g = try resolve(&.{"@zpm/window"}, &fetchWindowGraph); for (g.direct) |d| try testing.expect(d.is_direct); for (g.transitive) |d| try testing.expect(!d.is_direct); }
test "resolve: fetch fail" { try testing.expectError(error.FetchFailed, resolve(&.{"@x"}, &fetchAlwaysFails)); }
test "resolve: empty" { const g = try resolve(&.{}, &fetchAlwaysFails); try testing.expectEqual(@as(usize, 0), g.direct.len); }
test "resolve: diamond" { const g = try resolve(&.{"@zpm/app"}, &fetchDiamond); try testing.expectEqual(@as(usize, 4), g.direct.len + g.transitive.len); }
test "resolve: multi direct" { const g = try resolve(&.{ "@zpm/win32", "@zpm/gl" }, &fetchWindowGraph); try testing.expectEqual(@as(usize, 2), g.direct.len); }

// Property tests
var g_cyc_chain: [16][]const []const u8 = undefined;
var g_cyc_names: [16][]const u8 = undefined;
var g_cyc_len: usize = 0;
fn fetchCycP(sn: []const u8) FetchResult {
    for (0..g_cyc_len) |i| { if (strEql(sn, g_cyc_names[i])) return .{ .ok = .{ .scope = "t", .name = g_cyc_names[i], .version = "1.0.0", .url = "u", .hash = "h", .layer = 2, .system_libraries = &.{}, .zpm_dependencies = g_cyc_chain[i], .is_direct = false } }; }
    return .{ .err = error.FetchFailed };
}
var cyc_nbufs: [16][16]u8 = undefined;
var cyc_dslices: [16][1][]const u8 = undefined;
fn mkCycName(idx: usize) []const u8 { cyc_nbufs[idx][0] = '@'; cyc_nbufs[idx][1] = 't'; cyc_nbufs[idx][2] = '/'; cyc_nbufs[idx][3] = 'a' + @as(u8, @intCast(idx % 16)); return cyc_nbufs[idx][0..4]; }

test "prop: self-cycle" { g_cyc_names[0] = "@t/a"; g_cyc_chain[0] = &.{"@t/a"}; g_cyc_len = 1; try testing.expectError(error.CircularDependency, resolve(&.{"@t/a"}, &fetchCycP)); }
test "prop: 2-cycle" { g_cyc_names[0] = "@t/a"; g_cyc_chain[0] = &.{"@t/b"}; g_cyc_names[1] = "@t/b"; g_cyc_chain[1] = &.{"@t/a"}; g_cyc_len = 2; try testing.expectError(error.CircularDependency, resolve(&.{"@t/a"}, &fetchCycP)); }
test "prop: 3-cycle" { g_cyc_names[0] = "@t/a"; g_cyc_chain[0] = &.{"@t/b"}; g_cyc_names[1] = "@t/b"; g_cyc_chain[1] = &.{"@t/c"}; g_cyc_names[2] = "@t/c"; g_cyc_chain[2] = &.{"@t/a"}; g_cyc_len = 3; try testing.expectError(error.CircularDependency, resolve(&.{"@t/a"}, &fetchCycP)); }
test "prop: random cycles (200)" {
    var prng = std.Random.DefaultPrng.init(0xDEAD_BEEF_CAFE); const rand = prng.random();
    for (0..200) |iter| {
        const cl = rand.intRangeAtMost(usize, 2, 15);
        for (0..cl) |i| g_cyc_names[i] = mkCycName(i);
        for (0..cl) |i| { cyc_dslices[i][0] = g_cyc_names[(i + 1) % cl]; g_cyc_chain[i] = &cyc_dslices[i]; }
        g_cyc_len = cl;
        testing.expectError(error.CircularDependency, resolve(&.{g_cyc_names[0]}, &fetchCycP)) catch |err| { std.debug.print("FAIL iter={} cl={}\n", .{ iter, cl }); return err; };
    }
}

var g_tree_e: [8]ResolvedDep = undefined;
var g_tree_n: [8][]const u8 = undefined;
var g_tree_l: usize = 0;
fn fetchTreeP(sn: []const u8) FetchResult { for (0..g_tree_l) |i| { if (strEql(sn, g_tree_n[i])) return .{ .ok = g_tree_e[i] }; } return .{ .err = error.FetchFailed }; }
var tn_bufs: [8][16]u8 = undefined;
var td_bufs: [8][4][]const u8 = undefined;
var ts_bufs: [8][1][]const u8 = undefined;
const sl_pool = [_][]const u8{ "kernel32", "gdi32", "user32", "opengl32" };
fn mkTreeName(idx: usize) []const u8 { tn_bufs[idx] = .{ '@', 'p', '/', 'a' + @as(u8, @intCast(idx % 8)), 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }; return tn_bufs[idx][0..4]; }

test "prop: linear chain" {
    g_tree_n[0] = "@p/a"; g_tree_e[0] = .{ .scope = "p", .name = "a", .version = "1", .url = "u", .hash = "h", .layer = 2, .system_libraries = &.{"kernel32"}, .zpm_dependencies = &.{"@p/b"}, .is_direct = false };
    g_tree_n[1] = "@p/b"; g_tree_e[1] = .{ .scope = "p", .name = "b", .version = "1", .url = "u", .hash = "h", .layer = 1, .system_libraries = &.{"gdi32"}, .zpm_dependencies = &.{"@p/c"}, .is_direct = false };
    g_tree_n[2] = "@p/c"; g_tree_e[2] = .{ .scope = "p", .name = "c", .version = "1", .url = "u", .hash = "h", .layer = 0, .system_libraries = &.{}, .zpm_dependencies = &.{}, .is_direct = false };
    g_tree_l = 3; const g = try resolve(&.{"@p/a"}, &fetchTreeP); try testing.expectEqual(@as(usize, 3), g.direct.len + g.transitive.len);
}
test "prop: fan-out" {
    g_tree_n[0] = "@p/a"; g_tree_e[0] = .{ .scope = "p", .name = "a", .version = "1", .url = "u", .hash = "h", .layer = 2, .system_libraries = &.{}, .zpm_dependencies = &.{ "@p/b", "@p/c" }, .is_direct = false };
    g_tree_n[1] = "@p/b"; g_tree_e[1] = .{ .scope = "p", .name = "b", .version = "1", .url = "u", .hash = "h", .layer = 1, .system_libraries = &.{"opengl32"}, .zpm_dependencies = &.{}, .is_direct = false };
    g_tree_n[2] = "@p/c"; g_tree_e[2] = .{ .scope = "p", .name = "c", .version = "1", .url = "u", .hash = "h", .layer = 0, .system_libraries = &.{"user32"}, .zpm_dependencies = &.{}, .is_direct = false };
    g_tree_l = 3; const g = try resolve(&.{"@p/a"}, &fetchTreeP); try testing.expectEqual(@as(usize, 3), g.direct.len + g.transitive.len);
}
test "prop: random trees (200)" {
    var prng = std.Random.DefaultPrng.init(0xBEEF_CAFE_1234); const rand = prng.random();
    for (0..200) |iter| {
        const pc = rand.intRangeAtMost(usize, 2, 5);
        for (0..pc) |i| g_tree_n[i] = mkTreeName(i);
        for (0..pc) |i| {
            const lv: u2 = @intCast(@min(2, pc - 1 - i)); ts_bufs[i][0] = sl_pool[i % sl_pool.len];
            var dc: usize = 0;
            if (i + 1 < pc) { td_bufs[i][dc] = g_tree_n[i + 1]; dc += 1; }
            if (i + 2 < pc and rand.boolean()) { td_bufs[i][dc] = g_tree_n[i + 2]; dc += 1; }
            g_tree_e[i] = .{ .scope = "p", .name = g_tree_n[i], .version = "1", .url = "u", .hash = "h", .layer = lv, .system_libraries = &ts_bufs[i], .zpm_dependencies = td_bufs[i][0..dc], .is_direct = false };
        }
        g_tree_l = pc;
        const g = resolve(&.{g_tree_n[0]}, &fetchTreeP) catch |err| { if (err == error.LayerViolation) continue; std.debug.print("FAIL iter={}\n", .{iter}); return err; };
        try testing.expectEqual(pc, g.direct.len + g.transitive.len);
    }
}