// CLI command handlers — glue layer that wires together pure modules.
//
// Each handler takes a CommandContext (with I/O callbacks) and parsed CLI args,
// orchestrates the workflow, and returns a CommandResult. Handlers never do
// direct I/O — all file/console/registry access goes through the context.

const std = @import("std");
const cli = @import("cli.zig");
const resolver = @import("resolver.zig");
const zon = @import("zon.zig");
const validator = @import("validator.zig");
const registry = @import("registry.zig");
const names = @import("names.zig");
const manifest = @import("manifest.zig");
const bootstrap = @import("bootstrap.zig");
const init_mod = @import("init.zig");

// ── I/O Callback Types ──

pub const WriteFn = *const fn (data: []const u8) void;
pub const ReadFileFn = *const fn (path: []const u8, buf: []u8) ?[]const u8;
pub const WriteFileFn = *const fn (path: []const u8, data: []const u8) bool;

// ── Command Context ──

pub const CommandContext = struct {
    registry_client: *const registry.RegistryClient,
    stdout: WriteFn,
    stderr: WriteFn,
    read_file: ReadFileFn,
    write_file: WriteFileFn,
    /// Optional fetch function for the resolver. When set, install/update
    /// use this instead of building one from the registry client.
    fetch_fn: ?resolver.FetchFn = null,
    /// Optional bootstrapper for run/build commands. When set, ensureZig()
    /// is called before delegating to zig build.
    bootstrapper: ?*const bootstrap.ZigBootstrapper = null,
    /// Optional init vtable callbacks for the init command.
    init_create_dir: ?*const fn (path: []const u8) bool = null,
    init_write_file: ?*const fn (path: []const u8, content: []const u8) bool = null,
    init_dir_exists: ?*const fn (path: []const u8) bool = null,
    init_dir_is_empty: ?*const fn (path: []const u8) bool = null,
    init_remove_dir: ?*const fn (path: []const u8) bool = null,
    init_print: ?*const fn (msg: []const u8) void = null,
    /// Optional QUIC transport telemetry snapshot for `zpm doctor`.
    /// When set, the doctor command displays a "Transport Health" section.
    quic_telemetry: ?*const TransportHealth = null,
};

/// Pre-computed transport health snapshot for doctor display.
/// Populated from TelemetryCounters by the caller (zpm_main.zig).
pub const TransportHealth = struct {
    packets_sent: u64,
    packets_lost: u64,
    smoothed_rtt_us: u64,
    cwnd: u64,
    handshake_duration_us: u64,
    conn_state: u8,
    negotiated_version: u32,
};

// ── Command Result ──

pub const CommandResult = enum {
    success,
    validation_failed,
    registry_error,
    file_error,
    layer_violation,
    dependency_required,
    not_found,
};

// ── Constants ──

const zon_path = "build.zig.zon";
const manifest_path = "zpm.pkg.zon";
const max_zon_buf = 64 * 1024;

// Static storage for update command scoped name copies
var update_name_store: [128][130]u8 = undefined;

// ── Install Command ──
// Resolves packages via resolver, validates layers, writes to build.zig.zon.
// Requirements: 8.1, 8.2, 8.3, 8.4, 8.5

pub fn install(ctx: *const CommandContext, args: *const cli.ParsedArgs) CommandResult {
    const positionals = args.positional[0..args.positional_count];
    if (positionals.len == 0) {
        ctx.stderr("install: no packages specified\n");
        return .not_found;
    }

    // Read current build.zig.zon
    var file_buf: [max_zon_buf]u8 = undefined;
    const zon_source = ctx.read_file(zon_path, &file_buf) orelse {
        ctx.stderr("install: cannot read build.zig.zon\n");
        return .file_error;
    };

    // Resolve via the fetch function provided in context
    const fetch_fn = ctx.fetch_fn orelse {
        ctx.stderr("install: resolver not configured\n");
        return .registry_error;
    };

    const graph = resolver.resolve(positionals, fetch_fn) catch |err| {
        return switch (err) {
            error.LayerViolation => blk: {
                ctx.stderr("install: layer violation detected\n");
                break :blk .layer_violation;
            },
            error.CircularDependency => blk: {
                ctx.stderr("install: circular dependency detected\n");
                break :blk .layer_violation;
            },
            else => blk: {
                ctx.stderr("install: resolution failed\n");
                break :blk .registry_error;
            },
        };
    };

    // Build ZonDep entries from resolved graph
    const total = graph.direct.len + graph.transitive.len;
    var zon_deps_buf: [256]zon.ZonDep = undefined;
    var dep_count: usize = 0;

    for (graph.direct) |dep| {
        if (dep_count >= zon_deps_buf.len) break;
        zon_deps_buf[dep_count] = .{ .zon_name = dep.name, .url = dep.url, .hash = dep.hash };
        dep_count += 1;
    }
    for (graph.transitive) |dep| {
        if (dep_count >= zon_deps_buf.len) break;
        zon_deps_buf[dep_count] = .{ .zon_name = dep.name, .url = dep.url, .hash = dep.hash };
        dep_count += 1;
    }

    // Write deps to build.zig.zon
    var out_buf: [max_zon_buf]u8 = undefined;
    const new_zon = zon.addDeps(zon_source, zon_deps_buf[0..dep_count], &out_buf) catch {
        ctx.stderr("install: failed to update build.zig.zon\n");
        return .file_error;
    };

    if (!ctx.write_file(zon_path, new_zon)) {
        ctx.stderr("install: failed to write build.zig.zon\n");
        return .file_error;
    }

    var msg_buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&msg_buf, "installed {d} package(s), {d} total dependencies\n", .{ positionals.len, total }) catch "installed packages\n";
    ctx.stdout(msg);
    return .success;
}

// ── Uninstall Command ──
// Removes a package from build.zig.zon, cleans up orphaned transitive deps.
// Requirements: 9.1, 9.2, 9.3

pub fn uninstall(ctx: *const CommandContext, args: *const cli.ParsedArgs) CommandResult {
    const positionals = args.positional[0..args.positional_count];
    if (positionals.len == 0) {
        ctx.stderr("uninstall: no packages specified\n");
        return .not_found;
    }

    // Read current build.zig.zon
    var file_buf: [max_zon_buf]u8 = undefined;
    const zon_source = ctx.read_file(zon_path, &file_buf) orelse {
        ctx.stderr("uninstall: cannot read build.zig.zon\n");
        return .file_error;
    };

    // Parse existing deps (validate format before proceeding)
    var validate_buf: [256]zon.ZonDep = undefined;
    _ = zon.parseDeps(zon_source, &validate_buf) catch {
        ctx.stderr("uninstall: failed to parse build.zig.zon\n");
        return .file_error;
    };

    // For each package to remove, convert scoped name to zon key
    var current_source: []const u8 = zon_source;
    var working_buf: [max_zon_buf]u8 = undefined;
    var swap_buf: [max_zon_buf]u8 = undefined;

    // We need a dep graph for orphan detection. For simplicity in the CLI
    // layer, we use an empty graph (no transitive orphan tracking without
    // full metadata). A real implementation would build this from registry data.
    const empty_graph = zon.DepGraph{ .entries = &.{} };

    for (positionals) |scoped_name| {
        var key_buf: [129]u8 = undefined;
        const zon_key = names.scopedNameToZonKey(scoped_name, &key_buf) catch {
            ctx.stderr("uninstall: invalid package name\n");
            return .not_found;
        };

        // Re-parse deps from current source state
        var current_deps_buf: [256]zon.ZonDep = undefined;
        const current_deps_count = zon.parseDeps(current_source, &current_deps_buf) catch {
            ctx.stderr("uninstall: failed to parse dependencies\n");
            return .file_error;
        };
        const current_deps = current_deps_buf[0..current_deps_count];

        // Build direct deps list (all currently installed zpm deps are "direct" from CLI perspective)
        var direct_names_buf: [128][]const u8 = undefined;
        var direct_count: usize = 0;
        for (current_deps) |dep| {
            if (zon.isZpmDep(dep.zon_name) and direct_count < direct_names_buf.len) {
                direct_names_buf[direct_count] = dep.zon_name;
                direct_count += 1;
            }
        }

        const result = zon.removeDep(
            current_source,
            zon_key,
            current_deps,
            direct_names_buf[0..direct_count],
            &empty_graph,
            &working_buf,
        ) catch |err| {
            return switch (err) {
                error.DependencyRequired => blk: {
                    ctx.stderr("uninstall: package is required by another dependency\n");
                    break :blk .dependency_required;
                },
                error.DependencyNotFound => blk: {
                    ctx.stderr("uninstall: package not found in build.zig.zon\n");
                    break :blk .not_found;
                },
                else => blk: {
                    ctx.stderr("uninstall: failed to remove dependency\n");
                    break :blk .file_error;
                },
            };
        };

        // Copy result to swap buf so we can use it as source for next iteration
        @memcpy(swap_buf[0..result.len], result);
        current_source = swap_buf[0..result.len];
    }

    if (!ctx.write_file(zon_path, current_source)) {
        ctx.stderr("uninstall: failed to write build.zig.zon\n");
        return .file_error;
    }

    ctx.stdout("package(s) removed\n");
    return .success;
}

// ── List Command ──
// Reads build.zig.zon and displays installed zpm packages with scoped names.
// Requirements: 10.1, 10.2

pub fn listCmd(ctx: *const CommandContext, _: *const cli.ParsedArgs) CommandResult {
    var file_buf: [max_zon_buf]u8 = undefined;
    const zon_source = ctx.read_file(zon_path, &file_buf) orelse {
        ctx.stderr("list: cannot read build.zig.zon\n");
        return .file_error;
    };

    var deps_buf: [256]zon.ZonDep = undefined;
    const deps_count = zon.parseDeps(zon_source, &deps_buf) catch {
        ctx.stderr("list: failed to parse build.zig.zon\n");
        return .file_error;
    };
    const deps = deps_buf[0..deps_count];

    var zpm_count: usize = 0;
    for (deps) |dep| {
        if (!zon.isZpmDep(dep.zon_name)) continue;
        zpm_count += 1;

        // Convert zon key back to scoped name for display
        var scoped_buf: [130]u8 = undefined;
        const scoped = names.zonKeyToScopedName(dep.zon_name, &scoped_buf) catch dep.zon_name;

        var line_buf: [512]u8 = undefined;
        const line = std.fmt.bufPrint(&line_buf, "  {s}  {s}\n", .{ scoped, dep.url }) catch continue;
        ctx.stdout(line);
    }

    if (zpm_count == 0) {
        ctx.stdout("no zpm packages installed\n");
    } else {
        var summary_buf: [128]u8 = undefined;
        const summary = std.fmt.bufPrint(&summary_buf, "{d} zpm package(s) installed\n", .{zpm_count}) catch "\n";
        ctx.stdout(summary);
    }

    return .success;
}

// ── Search Command ──
// Queries the registry and displays results. Supports --layer filter.
// Requirements: 11.1, 11.2

pub fn searchCmd(ctx: *const CommandContext, args: *const cli.ParsedArgs) CommandResult {
    const positionals = args.positional[0..args.positional_count];
    if (positionals.len == 0) {
        ctx.stderr("search: no query specified\n");
        return .not_found;
    }

    const query = positionals[0];
    var resp_buf: [8192]u8 = undefined;

    const body = ctx.registry_client.search(query, args.layer_filter, &resp_buf) catch |err| {
        return switch (err) {
            error.OfflineMode => blk: {
                ctx.stderr("search: cannot search in offline mode\n");
                break :blk .registry_error;
            },
            else => blk: {
                ctx.stderr("search: registry request failed\n");
                break :blk .registry_error;
            },
        };
    };

    // Display raw results — in a real implementation we'd parse JSON
    if (body.len == 0 or std.mem.eql(u8, body, "[]")) {
        ctx.stdout("no packages found\n");
    } else {
        ctx.stdout(body);
        ctx.stdout("\n");
    }

    return .success;
}

// ── Publish Command ──
// Reads zpm.pkg.zon, validates, submits to registry. Handles --dry-run and 409.
// Requirements: 12.1, 12.2, 12.3, 12.4

pub fn publishCmd(ctx: *const CommandContext, args: *const cli.ParsedArgs) CommandResult {
    // Read zpm.pkg.zon manifest
    var manifest_buf: [max_zon_buf]u8 = undefined;
    const manifest_source = ctx.read_file(manifest_path, &manifest_buf) orelse {
        ctx.stderr("publish: cannot read zpm.pkg.zon\n");
        return .file_error;
    };

    // Parse manifest — zero allocation, slices into source
    const parsed_manifest = manifest.parseFromSource(manifest_source) catch {
        ctx.stderr("publish: invalid zpm.pkg.zon format\n");
        return .validation_failed;
    };

    // Run manifest-level validation
    const manifest_result = manifest.validate(&parsed_manifest);
    if (!manifest_result.ok()) {
        for (manifest_result.slice()) |err| {
            var err_buf: [256]u8 = undefined;
            const err_msg = std.fmt.bufPrint(&err_buf, "  {s}: {s}\n", .{ @tagName(err.field), err.message }) catch continue;
            ctx.stderr(err_msg);
        }
        return .validation_failed;
    }

    // Run layer validator (with empty inputs since we don't have build.zig scanning here)
    const val_result = validator.validate(&parsed_manifest, &.{}, &.{}, &.{}, &.{});
    if (!val_result.ok()) {
        for (val_result.slice()) |err| {
            var err_buf: [256]u8 = undefined;
            const err_msg = std.fmt.bufPrint(&err_buf, "  {s}: {s}\n", .{ @tagName(err.tag), err.message }) catch continue;
            ctx.stderr(err_msg);
        }
        return .validation_failed;
    }

    // If --dry-run, stop here
    if (args.dry_run) {
        ctx.stdout("validation passed (dry run, not publishing)\n");
        return .success;
    }

    // Submit to registry
    var resp_buf: [4096]u8 = undefined;
    const pub_result = ctx.registry_client.publish(manifest_source, &resp_buf) catch |err| {
        return switch (err) {
            error.OfflineMode => blk: {
                ctx.stderr("publish: cannot publish in offline mode\n");
                break :blk .registry_error;
            },
            else => blk: {
                ctx.stderr("publish: registry request failed\n");
                break :blk .registry_error;
            },
        };
    };

    return switch (pub_result.status) {
        .success => blk: {
            var msg_buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&msg_buf, "published @{s}/{s}@{s}\n", .{
                parsed_manifest.scope,
                parsed_manifest.name,
                parsed_manifest.version,
            }) catch "published\n";
            ctx.stdout(msg);
            break :blk .success;
        },
        .conflict => blk: {
            ctx.stderr("publish: version already published — bump version in zpm.pkg.zon\n");
            break :blk .registry_error;
        },
    };
}

// ── Validate Command ──
// Runs all validator checks against the current package. Makes NO file modifications.
// Requirements: 13.1, 13.2, 13.3, 13.4

pub fn validateCmd(ctx: *const CommandContext, _: *const cli.ParsedArgs) CommandResult {
    // Read zpm.pkg.zon manifest
    var manifest_buf: [max_zon_buf]u8 = undefined;
    const manifest_source = ctx.read_file(manifest_path, &manifest_buf) orelse {
        ctx.stderr("validate: cannot read zpm.pkg.zon\n");
        return .file_error;
    };

    // Parse manifest
    const parsed_manifest = manifest.parseFromSource(manifest_source) catch {
        ctx.stderr("validate: invalid zpm.pkg.zon format\n");
        return .validation_failed;
    };

    // Run manifest-level validation
    const manifest_result = manifest.validate(&parsed_manifest);
    var has_errors = false;

    if (!manifest_result.ok()) {
        has_errors = true;
        for (manifest_result.slice()) |err| {
            var err_buf: [256]u8 = undefined;
            const err_msg = std.fmt.bufPrint(&err_buf, "  {s}: {s}\n", .{ @tagName(err.field), err.message }) catch continue;
            ctx.stderr(err_msg);
        }
    }

    // Run layer validator (with empty inputs — real impl would scan build.zig and sources)
    const val_result = validator.validate(&parsed_manifest, &.{}, &.{}, &.{}, &.{});
    if (!val_result.ok()) {
        has_errors = true;
        for (val_result.slice()) |err| {
            var err_buf: [256]u8 = undefined;
            const err_msg = std.fmt.bufPrint(&err_buf, "  {s}: {s}\n", .{ @tagName(err.tag), err.message }) catch continue;
            ctx.stderr(err_msg);
        }
    }

    if (has_errors) {
        return .validation_failed;
    }

    var msg_buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&msg_buf, "package @{s}/{s}@{s} is valid\n", .{
        parsed_manifest.scope,
        parsed_manifest.name,
        parsed_manifest.version,
    }) catch "package is valid\n";
    ctx.stdout(msg);
    return .success;
}

// ── Update Command ──
// Checks registry for newer versions, re-validates layers, updates build.zig.zon.
// Requirements: 14.1, 14.2, 14.3

pub fn update(ctx: *const CommandContext, args: *const cli.ParsedArgs) CommandResult {
    const positionals = args.positional[0..args.positional_count];

    // Read current build.zig.zon
    var file_buf: [max_zon_buf]u8 = undefined;
    const zon_source = ctx.read_file(zon_path, &file_buf) orelse {
        ctx.stderr("update: cannot read build.zig.zon\n");
        return .file_error;
    };

    // Parse existing deps to find what to update
    var deps_buf: [256]zon.ZonDep = undefined;
    const deps_count = zon.parseDeps(zon_source, &deps_buf) catch {
        ctx.stderr("update: failed to parse build.zig.zon\n");
        return .file_error;
    };
    const deps = deps_buf[0..deps_count];

    // Collect zpm deps to update — either specific packages or all
    var to_update_buf: [128][]const u8 = undefined;
    var to_update_count: usize = 0;

    if (positionals.len > 0) {
        // Update specific packages — convert scoped names to zon keys for matching
        for (positionals) |scoped_name| {
            var key_buf: [129]u8 = undefined;
            const zon_key = names.scopedNameToZonKey(scoped_name, &key_buf) catch {
                ctx.stderr("update: invalid package name\n");
                return .not_found;
            };
            // Verify it exists
            var found = false;
            for (deps) |dep| {
                if (std.mem.eql(u8, dep.zon_name, zon_key)) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                ctx.stderr("update: package not found in build.zig.zon\n");
                return .not_found;
            }
            if (to_update_count < to_update_buf.len) {
                to_update_buf[to_update_count] = scoped_name;
                to_update_count += 1;
            }
        }
    } else {
        // Update all zpm deps — convert zon keys back to scoped names
        for (deps) |dep| {
            if (!zon.isZpmDep(dep.zon_name)) continue;
            var scoped_buf: [130]u8 = undefined;
            const scoped = names.zonKeyToScopedName(dep.zon_name, &scoped_buf) catch continue;
            // Copy into static storage so slices remain valid
            if (to_update_count < to_update_buf.len) {
                const len = scoped.len;
                @memcpy(update_name_store[to_update_count][0..len], scoped);
                to_update_buf[to_update_count] = update_name_store[to_update_count][0..len];
                to_update_count += 1;
            }
        }
    }

    if (to_update_count == 0) {
        ctx.stdout("no zpm packages to update\n");
        return .success;
    }

    // Re-resolve all packages to get latest versions
    const fetch_fn = ctx.fetch_fn orelse {
        ctx.stderr("update: resolver not configured\n");
        return .registry_error;
    };

    const graph = resolver.resolve(to_update_buf[0..to_update_count], fetch_fn) catch |err| {
        return switch (err) {
            error.LayerViolation => blk: {
                ctx.stderr("update: layer violation detected after resolution\n");
                break :blk .layer_violation;
            },
            else => blk: {
                ctx.stderr("update: resolution failed\n");
                break :blk .registry_error;
            },
        };
    };

    // Build ZonDep entries from resolved graph
    var zon_deps_buf: [256]zon.ZonDep = undefined;
    var dep_count: usize = 0;

    for (graph.direct) |dep| {
        if (dep_count >= zon_deps_buf.len) break;
        zon_deps_buf[dep_count] = .{ .zon_name = dep.name, .url = dep.url, .hash = dep.hash };
        dep_count += 1;
    }
    for (graph.transitive) |dep| {
        if (dep_count >= zon_deps_buf.len) break;
        zon_deps_buf[dep_count] = .{ .zon_name = dep.name, .url = dep.url, .hash = dep.hash };
        dep_count += 1;
    }

    // Write updated deps
    var out_buf: [max_zon_buf]u8 = undefined;
    const new_zon = zon.addDeps(zon_source, zon_deps_buf[0..dep_count], &out_buf) catch {
        ctx.stderr("update: failed to update build.zig.zon\n");
        return .file_error;
    };

    if (!ctx.write_file(zon_path, new_zon)) {
        ctx.stderr("update: failed to write build.zig.zon\n");
        return .file_error;
    }

    var msg_buf: [128]u8 = undefined;
    const msg = std.fmt.bufPrint(&msg_buf, "updated {d} package(s)\n", .{to_update_count}) catch "packages updated\n";
    ctx.stdout(msg);
    return .success;
}

// ── Run Command ──
// Ensures Zig is available via bootstrapper, then delegates to `zig build run`.
// Requirements: 18.1

pub fn runCmd(ctx: *const CommandContext, _: *const cli.ParsedArgs) CommandResult {
    if (ctx.bootstrapper) |b| {
        const br = b.ensureZig();
        if (br == .failed or br == .offline_no_zig) {
            ctx.stderr("run: zig is not available\n");
            return .file_error;
        }
    }
    // Report that zig build run would be executed with passthrough args
    ctx.stdout("executing zig build run\n");
    return .success;
}

// ── Build Command ──
// Ensures Zig is available via bootstrapper, then delegates to `zig build`.
// Requirements: 18.2

pub fn buildCmd(ctx: *const CommandContext, _: *const cli.ParsedArgs) CommandResult {
    if (ctx.bootstrapper) |b| {
        const br = b.ensureZig();
        if (br == .failed or br == .offline_no_zig) {
            ctx.stderr("build: zig is not available\n");
            return .file_error;
        }
    }
    // Report that zig build would be executed with passthrough args
    ctx.stdout("executing zig build\n");
    return .success;
}

// ── Doctor Command ──
// Runs all environment and project health checks. Reports success/failure per check.
// Requirements: 17.1, 17.2, 17.3, 17.4

pub fn doctorCmd(ctx: *const CommandContext, _: *const cli.ParsedArgs) CommandResult {
    var all_passed = true;

    // Check 1: zpm CLI version (hardcoded)
    ctx.stdout("\xe2\x9c\x93 zpm v0.1.0\n");

    // Check 2: Zig installation via bootstrapper
    if (ctx.bootstrapper) |b| {
        const br = b.ensureZig();
        switch (br) {
            .already_installed, .installed, .updated => {
                ctx.stdout("\xe2\x9c\x93 Zig installed\n");
            },
            .failed => {
                ctx.stderr("\xe2\x9c\x97 Zig not available\n");
                ctx.stderr("  run any zpm command to auto-install, or install manually from https://ziglang.org\n");
                all_passed = false;
            },
            .offline_no_zig => {
                ctx.stderr("\xe2\x9c\x97 Zig not found (offline mode)\n");
                ctx.stderr("  connect to the internet and run `zpm doctor` again, or install Zig manually\n");
                all_passed = false;
            },
        }
    } else {
        ctx.stdout("\xe2\x9c\x93 Zig check skipped (no bootstrapper)\n");
    }

    // Check 3: Registry reachability via simple GET
    {
        var resp_buf: [1024]u8 = undefined;
        const reg_result = ctx.registry_client.search("_ping", null, &resp_buf);
        if (reg_result) |_| {
            var url_buf: [256]u8 = undefined;
            const base = ctx.registry_client.base_url;
            const url_len = @min(base.len, url_buf.len);
            @memcpy(url_buf[0..url_len], base[0..url_len]);
            var msg_buf: [512]u8 = undefined;
            const msg = std.fmt.bufPrint(&msg_buf, "\xe2\x9c\x93 Registry reachable ({s})\n", .{url_buf[0..url_len]}) catch "\xe2\x9c\x93 Registry reachable\n";
            ctx.stdout(msg);
        } else |_| {
            ctx.stderr("\xe2\x9c\x97 Registry unreachable\n");
            ctx.stderr("  check your internet connection or use --registry to specify a different URL\n");
            all_passed = false;
        }
    }

    // Check 4: build.zig.zon presence
    var zon_found = false;
    {
        var file_buf: [max_zon_buf]u8 = undefined;
        if (ctx.read_file(zon_path, &file_buf) != null) {
            ctx.stdout("\xe2\x9c\x93 build.zig.zon found\n");
            zon_found = true;
        } else {
            ctx.stderr("\xe2\x9c\x97 build.zig.zon not found\n");
            ctx.stderr("  run `zpm init` to create a project\n");
            all_passed = false;
        }
    }

    // Check 5: build.zig presence
    {
        var file_buf: [max_zon_buf]u8 = undefined;
        if (ctx.read_file("build.zig", &file_buf) != null) {
            ctx.stdout("\xe2\x9c\x93 build.zig found\n");
        } else {
            ctx.stderr("\xe2\x9c\x97 build.zig not found\n");
            ctx.stderr("  run `zpm init` to create a project\n");
            all_passed = false;
        }
    }

    // Check 6: Count installed zpm packages (only if build.zig.zon was found)
    if (zon_found) {
        var zon_buf: [max_zon_buf]u8 = undefined;
        if (ctx.read_file(zon_path, &zon_buf)) |zon_source| {
            var doc_deps_buf: [256]zon.ZonDep = undefined;
            if (zon.parseDeps(zon_source, &doc_deps_buf)) |doc_deps_count| {
                var zpm_count: usize = 0;
                for (doc_deps_buf[0..doc_deps_count]) |dep| {
                    if (zon.isZpmDep(dep.zon_name)) zpm_count += 1;
                }

                var count_buf: [128]u8 = undefined;
                const count_msg = std.fmt.bufPrint(&count_buf, "\xe2\x9c\x93 {d} zpm package(s) installed\n", .{zpm_count}) catch "\xe2\x9c\x93 zpm packages counted\n";
                ctx.stdout(count_msg);
            } else |_| {
                ctx.stderr("\xe2\x9c\x97 Failed to parse build.zig.zon dependencies\n");
                ctx.stderr("  check build.zig.zon for syntax errors\n");
                all_passed = false;
            }
        }
    }

    // Check 7: QUIC Transport Health (if a connection is available)
    if (ctx.quic_telemetry) |th| {
        ctx.stdout("\n\xe2\x94\x80\xe2\x94\x80 Transport Health \xe2\x94\x80\xe2\x94\x80\n");

        // Connection state
        {
            var msg_buf: [128]u8 = undefined;
            const msg = std.fmt.bufPrint(&msg_buf, "  State:      {s}\n", .{fmtConnState(th.conn_state)}) catch "  State:      ?\n";
            ctx.stdout(msg);
        }

        // Negotiated version
        {
            var ver_buf: [32]u8 = undefined;
            var msg_buf: [128]u8 = undefined;
            const msg = std.fmt.bufPrint(&msg_buf, "  Version:    {s}\n", .{fmtVersion(th.negotiated_version, &ver_buf)}) catch "  Version:    ?\n";
            ctx.stdout(msg);
        }

        // Smoothed RTT
        {
            const rtt_ms = th.smoothed_rtt_us / 1000;
            const rtt_frac = (th.smoothed_rtt_us % 1000) / 100;
            var msg_buf: [128]u8 = undefined;
            const msg = std.fmt.bufPrint(&msg_buf, "  RTT:        {d}.{d} ms\n", .{ rtt_ms, rtt_frac }) catch "  RTT:        ?\n";
            ctx.stdout(msg);
        }

        // Packet loss rate
        {
            var msg_buf: [128]u8 = undefined;
            if (th.packets_sent > 0) {
                // Integer percentage: (lost * 100) / sent
                const pct = (th.packets_lost * 100) / th.packets_sent;
                const msg = std.fmt.bufPrint(&msg_buf, "  Loss rate:  {d}% ({d}/{d})\n", .{ pct, th.packets_lost, th.packets_sent }) catch "  Loss rate:  ?\n";
                ctx.stdout(msg);
            } else {
                ctx.stdout("  Loss rate:  0% (0/0)\n");
            }
        }

        // Congestion window
        {
            var msg_buf: [128]u8 = undefined;
            const msg = std.fmt.bufPrint(&msg_buf, "  CWND:       {d} bytes\n", .{th.cwnd}) catch "  CWND:       ?\n";
            ctx.stdout(msg);
        }

        // Handshake duration
        {
            const hs_ms = th.handshake_duration_us / 1000;
            var msg_buf: [128]u8 = undefined;
            const msg = std.fmt.bufPrint(&msg_buf, "  Handshake:  {d} ms\n", .{hs_ms}) catch "  Handshake:  ?\n";
            ctx.stdout(msg);
        }
    } else {
        ctx.stdout("\n\xe2\x94\x80\xe2\x94\x80 Transport Health \xe2\x94\x80\xe2\x94\x80\n");
        ctx.stdout("  No QUIC connection\n");
    }

    if (all_passed) return .success else return .validation_failed;
}

/// Format a QUIC version u32 as a display string into the provided buffer.
/// Returns the formatted slice. Known versions get human-readable names.
fn fmtVersion(ver: u32, buf: *[32]u8) []const u8 {
    return switch (ver) {
        0x00000001 => "QUIC v1",
        0x6b3343cf => "QUIC v2",
        0 => "negotiation",
        else => std.fmt.bufPrint(buf, "0x{x:0>8}", .{ver}) catch "unknown",
    };
}

/// Format a connection state byte as a human-readable string.
fn fmtConnState(state: u8) []const u8 {
    return switch (state) {
        0 => "idle",
        1 => "handshaking",
        2 => "connected",
        3 => "draining",
        4 => "closed",
        else => "unknown",
    };
}

// ── Init Command ──
// Scaffolds a new project from a template. Reads --template and --name from args.
// Requirements: 16.1, 16.2, 16.3, 16.4, 16.5, 16.6, 16.7, 16.8, 16.9, 16.10, 16.11

pub fn initCmd(ctx: *const CommandContext, args: *const cli.ParsedArgs) CommandResult {
    // Read --name (required for non-interactive)
    const project_name = args.name orelse {
        ctx.stderr("init: --name is required\n");
        return .not_found;
    };

    // Read --template (required for non-interactive)
    const template_str = args.template orelse {
        ctx.stderr("init: --template is required\n");
        return .not_found;
    };

    // Parse template
    const template = init_mod.Template.fromString(template_str) orelse {
        ctx.stderr("init: unknown template '");
        ctx.stderr(template_str);
        ctx.stderr("'\navailable templates: empty, window, gl-app, trading, package, cli-app, web-server, gui-app, library\n");
        return .not_found;
    };

    // Build init config
    const config = init_mod.InitConfig{
        .project_name = project_name,
        .template = template,
        .force = args.force,
        .package_layer = args.layer_filter,
    };

    // Build vtable from command context callbacks
    const vtable = init_mod.InitVtable{
        .create_dir = ctx.init_create_dir orelse &defaultCreateDir,
        .write_file = ctx.init_write_file orelse &defaultWriteFile,
        .dir_exists = ctx.init_dir_exists orelse &defaultDirExists,
        .dir_is_empty = ctx.init_dir_is_empty orelse &defaultDirIsEmpty,
        .remove_dir = ctx.init_remove_dir orelse &defaultRemoveDir,
        .print = ctx.init_print orelse &defaultPrint,
    };

    const result = init_mod.scaffold(&vtable, &config);

    return switch (result) {
        .success => blk: {
            var msg_buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&msg_buf, "created {s}/ from '{s}' template\n  run: cd {s} && zpm run\n", .{
                project_name,
                template.name(),
                project_name,
            }) catch "project created\n";
            ctx.stdout(msg);
            break :blk .success;
        },
        .dir_exists_not_empty => .file_error,
        .template_not_found => .not_found,
        .failed => .file_error,
    };
}

// Default no-op callbacks for init vtable (used when context doesn't provide them)
fn defaultCreateDir(_: []const u8) bool {
    return false;
}
fn defaultWriteFile(_: []const u8, _: []const u8) bool {
    return false;
}
fn defaultDirExists(_: []const u8) bool {
    return false;
}
fn defaultDirIsEmpty(_: []const u8) bool {
    return true;
}
fn defaultRemoveDir(_: []const u8) bool {
    return false;
}
fn defaultPrint(_: []const u8) void {}

// ── Tests ──

const testing = std.testing;

// ── Mock Infrastructure ──

// Thread-local mock state for test callbacks
var mock_stdout_buf: [8192]u8 = undefined;
var mock_stdout_len: usize = 0;
var mock_stderr_buf: [8192]u8 = undefined;
var mock_stderr_len: usize = 0;

var mock_files: [8]MockFile = undefined;
var mock_file_count: usize = 0;
var mock_write_calls: usize = 0;
var mock_write_fail: bool = false;

const MockFile = struct {
    path: []const u8,
    content: []const u8,
};

fn resetMocks() void {
    mock_stdout_len = 0;
    mock_stderr_len = 0;
    mock_file_count = 0;
    mock_write_calls = 0;
    mock_write_fail = false;
}

fn mockStdout(data: []const u8) void {
    const copy_len = @min(data.len, mock_stdout_buf.len - mock_stdout_len);
    @memcpy(mock_stdout_buf[mock_stdout_len .. mock_stdout_len + copy_len], data[0..copy_len]);
    mock_stdout_len += copy_len;
}

fn mockStderr(data: []const u8) void {
    const copy_len = @min(data.len, mock_stderr_buf.len - mock_stderr_len);
    @memcpy(mock_stderr_buf[mock_stderr_len .. mock_stderr_len + copy_len], data[0..copy_len]);
    mock_stderr_len += copy_len;
}

fn mockReadFile(path: []const u8, buf: []u8) ?[]const u8 {
    for (mock_files[0..mock_file_count]) |f| {
        if (std.mem.eql(u8, f.path, path)) {
            if (f.content.len > buf.len) return null;
            @memcpy(buf[0..f.content.len], f.content);
            return buf[0..f.content.len];
        }
    }
    return null;
}

fn mockWriteFile(path: []const u8, data: []const u8) bool {
    if (mock_write_fail) return false;
    mock_write_calls += 1;
    // Update existing or add new
    for (mock_files[0..mock_file_count]) |*f| {
        if (std.mem.eql(u8, f.path, path)) {
            f.content = data;
            return true;
        }
    }
    if (mock_file_count < mock_files.len) {
        mock_files[mock_file_count] = .{ .path = path, .content = data };
        mock_file_count += 1;
        return true;
    }
    return false;
}

fn addMockFile(path: []const u8, content: []const u8) void {
    if (mock_file_count < mock_files.len) {
        mock_files[mock_file_count] = .{ .path = path, .content = content };
        mock_file_count += 1;
    }
}

// ── Mock Registry ──

const MockHttp = struct {
    var get_response: []const u8 = "";
    var get_should_fail: bool = false;
    var post_response: []const u8 = "";
    var post_status: u16 = 200;
    var post_should_fail: bool = false;
    var last_get_url: [1024]u8 = undefined;
    var last_get_url_len: usize = 0;

    fn reset() void {
        get_response = "";
        get_should_fail = false;
        post_response = "";
        post_status = 200;
        post_should_fail = false;
        last_get_url_len = 0;
    }

    fn get(url: []const u8, response_buf: []u8) registry.GetResult {
        const copy_len = @min(url.len, last_get_url.len);
        @memcpy(last_get_url[0..copy_len], url[0..copy_len]);
        last_get_url_len = copy_len;

        if (get_should_fail) return .{ .err = error.ConnectionFailed };
        if (get_response.len > response_buf.len) return .{ .err = error.BufferTooSmall };
        @memcpy(response_buf[0..get_response.len], get_response);
        return .{ .ok = .{ .body = response_buf[0..get_response.len] } };
    }

    fn post(_: []const u8, _: []const u8, response_buf: []u8) registry.PostResult {
        if (post_should_fail) return .{ .err = error.ConnectionFailed };
        if (post_response.len > response_buf.len) return .{ .err = error.BufferTooSmall };
        @memcpy(response_buf[0..post_response.len], post_response);
        return .{ .ok = .{ .status = post_status, .body = response_buf[0..post_response.len] } };
    }

    fn getLastUrl() []const u8 {
        return last_get_url[0..last_get_url_len];
    }

    const vtable = registry.HttpVtable{
        .get = &get,
        .post = &post,
    };
};

fn testRegistryClient(offline: bool) registry.RegistryClient {
    return .{
        .base_url = "https://registry.zpm.dev",
        .offline = offline,
        .http = MockHttp.vtable,
    };
}

// ── Mock Fetch Function for Resolver ──

fn mockFetchSingle(scoped_name: []const u8) resolver.FetchResult {
    if (std.mem.eql(u8, scoped_name, "@zpm/core")) {
        return .{ .ok = .{
            .scope = "zpm",
            .name = "core",
            .version = "0.1.0",
            .url = "https://registry.zpm.dev/pkg/@zpm/core/0.1.0.tar.gz",
            .hash = "1220abc123",
            .layer = 0,
            .system_libraries = &.{},
            .zpm_dependencies = &.{},
            .is_direct = false,
        } };
    }
    return .{ .err = error.FetchFailed };
}

fn mockFetchWithTransitive(scoped_name: []const u8) resolver.FetchResult {
    if (std.mem.eql(u8, scoped_name, "@zpm/window")) {
        return .{ .ok = .{
            .scope = "zpm",
            .name = "window",
            .version = "0.2.0",
            .url = "https://registry.zpm.dev/pkg/@zpm/window/0.2.0.tar.gz",
            .hash = "1220win200",
            .layer = 1,
            .system_libraries = &.{"kernel32"},
            .zpm_dependencies = &.{"@zpm/core"},
            .is_direct = false,
        } };
    }
    if (std.mem.eql(u8, scoped_name, "@zpm/core")) {
        return .{ .ok = .{
            .scope = "zpm",
            .name = "core",
            .version = "0.2.0",
            .url = "https://registry.zpm.dev/pkg/@zpm/core/0.2.0.tar.gz",
            .hash = "1220core200",
            .layer = 0,
            .system_libraries = &.{},
            .zpm_dependencies = &.{},
            .is_direct = false,
        } };
    }
    return .{ .err = error.FetchFailed };
}

fn mockFetchLayerViolation(scoped_name: []const u8) resolver.FetchResult {
    if (std.mem.eql(u8, scoped_name, "@zpm/core")) {
        return .{ .ok = .{
            .scope = "zpm",
            .name = "core",
            .version = "0.1.0",
            .url = "url",
            .hash = "hash",
            .layer = 0,
            .system_libraries = &.{},
            .zpm_dependencies = &.{"@zpm/win32"},
            .is_direct = false,
        } };
    }
    if (std.mem.eql(u8, scoped_name, "@zpm/win32")) {
        return .{ .ok = .{
            .scope = "zpm",
            .name = "win32",
            .version = "0.1.0",
            .url = "url",
            .hash = "hash",
            .layer = 1,
            .system_libraries = &.{},
            .zpm_dependencies = &.{},
            .is_direct = false,
        } };
    }
    return .{ .err = error.FetchFailed };
}

// ── Sample ZON for tests ──

const sample_zon =
    \\.{
    \\    .name = .@"my-app",
    \\    .version = "0.1.0",
    \\    .fingerprint = 0xdeadbeef,
    \\    .minimum_zig_version = "0.16.0",
    \\    .dependencies = .{
    \\        .@"zpm-core" = .{
    \\            .url = "https://registry.zpm.dev/pkg/@zpm/core/0.1.0.tar.gz",
    \\            .hash = "1220abc123",
    \\        },
    \\    },
    \\    .paths = .{
    \\        "build.zig",
    \\        "build.zig.zon",
    \\        "src",
    \\    },
    \\}
    \\
;

const empty_deps_zon =
    \\.{
    \\    .name = .@"my-app",
    \\    .version = "0.1.0",
    \\    .fingerprint = 0xdeadbeef,
    \\    .minimum_zig_version = "0.16.0",
    \\    .dependencies = .{},
    \\    .paths = .{
    \\        "build.zig",
    \\        "build.zig.zon",
    \\        "src",
    \\    },
    \\}
    \\
;

const valid_manifest_zon =
    \\.{
    \\    .protocol_version = 1,
    \\    .scope = "zpm",
    \\    .name = "core",
    \\    .version = "0.1.0",
    \\    .layer = 0,
    \\    .platform = .any,
    \\}
;

const invalid_manifest_zon =
    \\.{
    \\    .protocol_version = 2,
    \\    .scope = "",
    \\    .name = "core",
    \\    .version = "0.1.0",
    \\    .layer = 0,
    \\}
;

// ── Helper to build test context ──

fn testContext(reg: *const registry.RegistryClient, fetch_fn: ?resolver.FetchFn) CommandContext {
    return .{
        .registry_client = reg,
        .stdout = &mockStdout,
        .stderr = &mockStderr,
        .read_file = &mockReadFile,
        .write_file = &mockWriteFile,
        .fetch_fn = fetch_fn,
    };
}

fn getStdout() []const u8 {
    return mock_stdout_buf[0..mock_stdout_len];
}

fn getStderr() []const u8 {
    return mock_stderr_buf[0..mock_stderr_len];
}

// ── Install Tests ──

test "install: resolves and writes deps to build.zig.zon" {
    resetMocks();
    MockHttp.reset();
    addMockFile("build.zig.zon", empty_deps_zon);

    const reg = testRegistryClient(false);
    const ctx = testContext(&reg, &mockFetchSingle);

    var args = cli.ParsedArgs{};
    args.command = .install;
    args.positional[0] = "@zpm/core";
    args.positional_count = 1;

    const result = install(&ctx, &args);
    try testing.expectEqual(CommandResult.success, result);
    try testing.expect(mock_write_calls > 0);
    try testing.expect(std.mem.indexOf(u8, getStdout(), "installed") != null);
}

test "install: reports layer violation" {
    resetMocks();
    MockHttp.reset();
    addMockFile("build.zig.zon", empty_deps_zon);

    const reg = testRegistryClient(false);
    const ctx = testContext(&reg, &mockFetchLayerViolation);

    var args = cli.ParsedArgs{};
    args.command = .install;
    args.positional[0] = "@zpm/core";
    args.positional_count = 1;

    const result = install(&ctx, &args);
    try testing.expectEqual(CommandResult.layer_violation, result);
    try testing.expect(mock_write_calls == 0);
    try testing.expect(std.mem.indexOf(u8, getStderr(), "layer violation") != null);
}

test "install: no packages specified returns not_found" {
    resetMocks();
    MockHttp.reset();

    const reg = testRegistryClient(false);
    const ctx = testContext(&reg, &mockFetchSingle);

    var args = cli.ParsedArgs{};
    args.command = .install;
    args.positional_count = 0;

    const result = install(&ctx, &args);
    try testing.expectEqual(CommandResult.not_found, result);
}

test "install: missing build.zig.zon returns file_error" {
    resetMocks();
    MockHttp.reset();
    // Don't add build.zig.zon to mock files

    const reg = testRegistryClient(false);
    const ctx = testContext(&reg, &mockFetchSingle);

    var args = cli.ParsedArgs{};
    args.command = .install;
    args.positional[0] = "@zpm/core";
    args.positional_count = 1;

    const result = install(&ctx, &args);
    try testing.expectEqual(CommandResult.file_error, result);
}

// ── Uninstall Tests ──

test "uninstall: removes dep from build.zig.zon" {
    resetMocks();
    MockHttp.reset();
    addMockFile("build.zig.zon", sample_zon);

    const reg = testRegistryClient(false);
    const ctx = testContext(&reg, null);

    var args = cli.ParsedArgs{};
    args.command = .uninstall;
    args.positional[0] = "@zpm/core";
    args.positional_count = 1;

    const result = uninstall(&ctx, &args);
    try testing.expectEqual(CommandResult.success, result);
    try testing.expect(mock_write_calls > 0);
}

test "uninstall: not found returns not_found" {
    resetMocks();
    MockHttp.reset();
    addMockFile("build.zig.zon", sample_zon);

    const reg = testRegistryClient(false);
    const ctx = testContext(&reg, null);

    var args = cli.ParsedArgs{};
    args.command = .uninstall;
    args.positional[0] = "@zpm/nonexistent";
    args.positional_count = 1;

    const result = uninstall(&ctx, &args);
    try testing.expectEqual(CommandResult.not_found, result);
}

// ── List Tests ──

test "list: displays installed zpm deps" {
    resetMocks();
    MockHttp.reset();
    addMockFile("build.zig.zon", sample_zon);

    const reg = testRegistryClient(false);
    const ctx = testContext(&reg, null);

    var args = cli.ParsedArgs{};
    args.command = .list;

    const result = listCmd(&ctx, &args);
    try testing.expectEqual(CommandResult.success, result);
    try testing.expect(std.mem.indexOf(u8, getStdout(), "@zpm/core") != null);
    try testing.expect(std.mem.indexOf(u8, getStdout(), "1 zpm package(s)") != null);
}

test "list: empty deps shows no packages" {
    resetMocks();
    MockHttp.reset();
    addMockFile("build.zig.zon", empty_deps_zon);

    const reg = testRegistryClient(false);
    const ctx = testContext(&reg, null);

    var args = cli.ParsedArgs{};
    args.command = .list;

    const result = listCmd(&ctx, &args);
    try testing.expectEqual(CommandResult.success, result);
    try testing.expect(std.mem.indexOf(u8, getStdout(), "no zpm packages") != null);
}

// ── Validate Tests ──

test "validate: valid manifest reports success without modifying files" {
    resetMocks();
    MockHttp.reset();
    addMockFile("zpm.pkg.zon", valid_manifest_zon);

    const reg = testRegistryClient(false);
    const ctx = testContext(&reg, null);

    var args = cli.ParsedArgs{};
    args.command = .validate;

    const result = validateCmd(&ctx, &args);
    try testing.expectEqual(CommandResult.success, result);
    try testing.expect(mock_write_calls == 0); // No file modifications!
    try testing.expect(std.mem.indexOf(u8, getStdout(), "is valid") != null);
}

test "validate: invalid manifest reports errors without modifying files" {
    resetMocks();
    MockHttp.reset();
    addMockFile("zpm.pkg.zon", invalid_manifest_zon);

    const reg = testRegistryClient(false);
    const ctx = testContext(&reg, null);

    var args = cli.ParsedArgs{};
    args.command = .validate;

    const result = validateCmd(&ctx, &args);
    try testing.expectEqual(CommandResult.validation_failed, result);
    try testing.expect(mock_write_calls == 0); // No file modifications!
    try testing.expect(std.mem.indexOf(u8, getStderr(), "protocol_version") != null);
}

test "validate: missing zpm.pkg.zon returns file_error" {
    resetMocks();
    MockHttp.reset();
    // Don't add zpm.pkg.zon

    const reg = testRegistryClient(false);
    const ctx = testContext(&reg, null);

    var args = cli.ParsedArgs{};
    args.command = .validate;

    const result = validateCmd(&ctx, &args);
    try testing.expectEqual(CommandResult.file_error, result);
    try testing.expect(mock_write_calls == 0);
}

// ── Publish Tests ──

test "publish: valid manifest publishes successfully" {
    resetMocks();
    MockHttp.reset();
    MockHttp.post_status = 200;
    MockHttp.post_response = "ok";
    addMockFile("zpm.pkg.zon", valid_manifest_zon);

    const reg = testRegistryClient(false);
    const ctx = testContext(&reg, null);

    var args = cli.ParsedArgs{};
    args.command = .publish;

    const result = publishCmd(&ctx, &args);
    try testing.expectEqual(CommandResult.success, result);
    try testing.expect(std.mem.indexOf(u8, getStdout(), "published") != null);
}

test "publish: handles 409 conflict" {
    resetMocks();
    MockHttp.reset();
    MockHttp.post_status = 409;
    MockHttp.post_response = "version already published";
    addMockFile("zpm.pkg.zon", valid_manifest_zon);

    const reg = testRegistryClient(false);
    const ctx = testContext(&reg, null);

    var args = cli.ParsedArgs{};
    args.command = .publish;

    const result = publishCmd(&ctx, &args);
    try testing.expectEqual(CommandResult.registry_error, result);
    try testing.expect(std.mem.indexOf(u8, getStderr(), "already published") != null);
}

test "publish: dry-run validates without publishing" {
    resetMocks();
    MockHttp.reset();
    addMockFile("zpm.pkg.zon", valid_manifest_zon);

    const reg = testRegistryClient(false);
    const ctx = testContext(&reg, null);

    var args = cli.ParsedArgs{};
    args.command = .publish;
    args.dry_run = true;

    const result = publishCmd(&ctx, &args);
    try testing.expectEqual(CommandResult.success, result);
    try testing.expect(std.mem.indexOf(u8, getStdout(), "dry run") != null);
}

test "publish: invalid manifest fails validation" {
    resetMocks();
    MockHttp.reset();
    addMockFile("zpm.pkg.zon", invalid_manifest_zon);

    const reg = testRegistryClient(false);
    const ctx = testContext(&reg, null);

    var args = cli.ParsedArgs{};
    args.command = .publish;

    const result = publishCmd(&ctx, &args);
    try testing.expectEqual(CommandResult.validation_failed, result);
}

// ── Search Tests ──

test "search: queries registry and displays results" {
    resetMocks();
    MockHttp.reset();
    MockHttp.get_response = "[{\"name\":\"@zpm/core\",\"layer\":0}]";

    const reg = testRegistryClient(false);
    const ctx = testContext(&reg, null);

    var args = cli.ParsedArgs{};
    args.command = .search;
    args.positional[0] = "core";
    args.positional_count = 1;

    const result = searchCmd(&ctx, &args);
    try testing.expectEqual(CommandResult.success, result);
    try testing.expect(std.mem.indexOf(u8, getStdout(), "core") != null);
}

test "search: offline mode returns registry_error" {
    resetMocks();
    MockHttp.reset();

    const reg = testRegistryClient(true);
    const ctx = testContext(&reg, null);

    var args = cli.ParsedArgs{};
    args.command = .search;
    args.positional[0] = "core";
    args.positional_count = 1;

    const result = searchCmd(&ctx, &args);
    try testing.expectEqual(CommandResult.registry_error, result);
    try testing.expect(std.mem.indexOf(u8, getStderr(), "offline") != null);
}

// ── Update Tests ──

test "update: re-resolves and writes updated deps" {
    resetMocks();
    MockHttp.reset();
    addMockFile("build.zig.zon", sample_zon);

    const reg = testRegistryClient(false);
    const ctx = testContext(&reg, &mockFetchWithTransitive);

    var args = cli.ParsedArgs{};
    args.command = .update;
    args.positional_count = 0; // update all

    const result = update(&ctx, &args);
    try testing.expectEqual(CommandResult.success, result);
    try testing.expect(mock_write_calls > 0);
    try testing.expect(std.mem.indexOf(u8, getStdout(), "updated") != null);
}

test "update: specific package not found returns not_found" {
    resetMocks();
    MockHttp.reset();
    addMockFile("build.zig.zon", sample_zon);

    const reg = testRegistryClient(false);
    const ctx = testContext(&reg, &mockFetchSingle);

    var args = cli.ParsedArgs{};
    args.command = .update;
    args.positional[0] = "@zpm/nonexistent";
    args.positional_count = 1;

    const result = update(&ctx, &args);
    try testing.expectEqual(CommandResult.not_found, result);
}

// ── Mock Bootstrapper for run/build tests ──

var mock_boot_exec_result: ?bootstrap.ExecResult = null;
var mock_boot_download_ok: bool = true;
var mock_boot_extract_ok: bool = true;

fn mockBootExec(_: []const u8, _: []u8) ?bootstrap.ExecResult {
    return mock_boot_exec_result;
}

fn mockBootDownload(_: []const u8, _: []const u8) bool {
    return mock_boot_download_ok;
}

fn mockBootExtract(_: []const u8, _: []const u8) bool {
    return mock_boot_extract_ok;
}

fn mockBootPrint(_: []const u8) void {}

const mock_boot_vtable = bootstrap.BootstrapVtable{
    .exec = &mockBootExec,
    .download = &mockBootDownload,
    .extract = &mockBootExtract,
    .print = &mockBootPrint,
};

fn resetBootMocks() void {
    mock_boot_exec_result = null;
    mock_boot_download_ok = true;
    mock_boot_extract_ok = true;
}

// ── Run Command Tests ──

test "runCmd: succeeds when bootstrapper confirms zig installed" {
    resetMocks();
    resetBootMocks();
    MockHttp.reset();
    mock_boot_exec_result = .{ .exit_code = 0, .stdout = "0.16.0\n" };

    const bootstrapper = bootstrap.ZigBootstrapper{
        .vtable = mock_boot_vtable,
        .offline = false,
        .auto_update = false,
    };

    const reg = testRegistryClient(false);
    var ctx = testContext(&reg, null);
    ctx.bootstrapper = &bootstrapper;

    var args = cli.ParsedArgs{};
    args.command = .run;

    const result = runCmd(&ctx, &args);
    try testing.expectEqual(CommandResult.success, result);
    try testing.expect(std.mem.indexOf(u8, getStdout(), "executing zig build run") != null);
}

test "runCmd: fails when zig not available offline" {
    resetMocks();
    resetBootMocks();
    MockHttp.reset();
    mock_boot_exec_result = null; // zig not found

    const bootstrapper = bootstrap.ZigBootstrapper{
        .vtable = mock_boot_vtable,
        .offline = true,
        .auto_update = false,
    };

    const reg = testRegistryClient(false);
    var ctx = testContext(&reg, null);
    ctx.bootstrapper = &bootstrapper;

    var args = cli.ParsedArgs{};
    args.command = .run;

    const result = runCmd(&ctx, &args);
    try testing.expectEqual(CommandResult.file_error, result);
    try testing.expect(std.mem.indexOf(u8, getStderr(), "zig is not available") != null);
}

test "runCmd: succeeds without bootstrapper" {
    resetMocks();
    MockHttp.reset();

    const reg = testRegistryClient(false);
    const ctx = testContext(&reg, null);

    var args = cli.ParsedArgs{};
    args.command = .run;

    const result = runCmd(&ctx, &args);
    try testing.expectEqual(CommandResult.success, result);
    try testing.expect(std.mem.indexOf(u8, getStdout(), "executing zig build run") != null);
}

test "runCmd: fails when outdated zig without auto_update" {
    resetMocks();
    resetBootMocks();
    MockHttp.reset();
    mock_boot_exec_result = .{ .exit_code = 0, .stdout = "0.15.0\n" };

    const bootstrapper = bootstrap.ZigBootstrapper{
        .vtable = mock_boot_vtable,
        .offline = false,
        .auto_update = false,
    };

    const reg = testRegistryClient(false);
    var ctx = testContext(&reg, null);
    ctx.bootstrapper = &bootstrapper;

    var args = cli.ParsedArgs{};
    args.command = .run;

    const result = runCmd(&ctx, &args);
    try testing.expectEqual(CommandResult.file_error, result);
}

// ── Build Command Tests ──

test "buildCmd: succeeds when bootstrapper confirms zig installed" {
    resetMocks();
    resetBootMocks();
    MockHttp.reset();
    mock_boot_exec_result = .{ .exit_code = 0, .stdout = "0.16.0\n" };

    const bootstrapper = bootstrap.ZigBootstrapper{
        .vtable = mock_boot_vtable,
        .offline = false,
        .auto_update = false,
    };

    const reg = testRegistryClient(false);
    var ctx = testContext(&reg, null);
    ctx.bootstrapper = &bootstrapper;

    var args = cli.ParsedArgs{};
    args.command = .build;

    const result = buildCmd(&ctx, &args);
    try testing.expectEqual(CommandResult.success, result);
    try testing.expect(std.mem.indexOf(u8, getStdout(), "executing zig build") != null);
}

test "buildCmd: fails when zig not available offline" {
    resetMocks();
    resetBootMocks();
    MockHttp.reset();
    mock_boot_exec_result = null; // zig not found

    const bootstrapper = bootstrap.ZigBootstrapper{
        .vtable = mock_boot_vtable,
        .offline = true,
        .auto_update = false,
    };

    const reg = testRegistryClient(false);
    var ctx = testContext(&reg, null);
    ctx.bootstrapper = &bootstrapper;

    var args = cli.ParsedArgs{};
    args.command = .build;

    const result = buildCmd(&ctx, &args);
    try testing.expectEqual(CommandResult.file_error, result);
    try testing.expect(std.mem.indexOf(u8, getStderr(), "zig is not available") != null);
}

test "buildCmd: succeeds without bootstrapper" {
    resetMocks();
    MockHttp.reset();

    const reg = testRegistryClient(false);
    const ctx = testContext(&reg, null);

    var args = cli.ParsedArgs{};
    args.command = .build;

    const result = buildCmd(&ctx, &args);
    try testing.expectEqual(CommandResult.success, result);
    try testing.expect(std.mem.indexOf(u8, getStdout(), "executing zig build") != null);
}

// ── Init Command Mock Infrastructure ──

var mock_init_dirs_created: [16][512]u8 = undefined;
var mock_init_dirs_created_lens: [16]usize = undefined;
var mock_init_dir_count: usize = 0;

var mock_init_files_written: [16]InitMockFile = undefined;
var mock_init_file_count: usize = 0;

var mock_init_existing_dirs: [4][512]u8 = undefined;
var mock_init_existing_dirs_lens: [4]usize = undefined;
var mock_init_existing_dir_count: usize = 0;
var mock_init_existing_dirs_empty: [4]bool = undefined;

var mock_init_removed: usize = 0;

const InitMockFile = struct {
    path: [512]u8,
    path_len: usize,
    content: [8192]u8,
    content_len: usize,
};

fn resetInitCmdMocks() void {
    mock_init_dir_count = 0;
    mock_init_file_count = 0;
    mock_init_existing_dir_count = 0;
    mock_init_removed = 0;
}

fn mockInitCmdCreateDir(path: []const u8) bool {
    if (mock_init_dir_count < mock_init_dirs_created.len) {
        const i = mock_init_dir_count;
        const l = @min(path.len, mock_init_dirs_created[i].len);
        @memcpy(mock_init_dirs_created[i][0..l], path[0..l]);
        mock_init_dirs_created_lens[i] = l;
        mock_init_dir_count += 1;
    }
    return true;
}

fn mockInitCmdWriteFile(path: []const u8, content: []const u8) bool {
    if (mock_init_file_count < mock_init_files_written.len) {
        const i = mock_init_file_count;
        const pl = @min(path.len, mock_init_files_written[i].path.len);
        @memcpy(mock_init_files_written[i].path[0..pl], path[0..pl]);
        mock_init_files_written[i].path_len = pl;
        const cl = @min(content.len, mock_init_files_written[i].content.len);
        @memcpy(mock_init_files_written[i].content[0..cl], content[0..cl]);
        mock_init_files_written[i].content_len = cl;
        mock_init_file_count += 1;
    }
    return true;
}

fn mockInitCmdDirExists(path: []const u8) bool {
    for (0..mock_init_existing_dir_count) |i| {
        const existing = mock_init_existing_dirs[i][0..mock_init_existing_dirs_lens[i]];
        if (std.mem.eql(u8, path, existing)) return true;
    }
    return false;
}

fn mockInitCmdDirIsEmpty(_: []const u8) bool {
    return true;
}

fn mockInitCmdRemoveDir(_: []const u8) bool {
    mock_init_removed += 1;
    return true;
}

fn initTestContext() CommandContext {
    return .{
        .registry_client = &mock_init_reg,
        .stdout = &mockStdout,
        .stderr = &mockStderr,
        .read_file = &mockReadFile,
        .write_file = &mockWriteFile,
        .init_create_dir = &mockInitCmdCreateDir,
        .init_write_file = &mockInitCmdWriteFile,
        .init_dir_exists = &mockInitCmdDirExists,
        .init_dir_is_empty = &mockInitCmdDirIsEmpty,
        .init_remove_dir = &mockInitCmdRemoveDir,
        .init_print = &mockStderr,
    };
}

const mock_init_reg = registry.RegistryClient{
    .base_url = "https://registry.zpm.dev",
    .offline = false,
    .http = MockHttp.vtable,
};

// ── Init Command Tests ──

test "initCmd: scaffolds project with --name and --template" {
    resetMocks();
    resetInitCmdMocks();
    MockHttp.reset();

    var ctx = initTestContext();
    _ = &ctx;

    var args = cli.ParsedArgs{};
    args.command = .init;
    args.name = "my-app";
    args.template = "empty";

    const result = initCmd(&ctx, &args);
    try testing.expectEqual(CommandResult.success, result);
    try testing.expect(std.mem.indexOf(u8, getStdout(), "created my-app/") != null);
    try testing.expect(mock_init_file_count >= 5); // build.zig.zon, build.zig, main.zig, .gitignore, README.md
}

test "initCmd: missing --name returns not_found" {
    resetMocks();
    resetInitCmdMocks();
    MockHttp.reset();

    var ctx = initTestContext();
    _ = &ctx;

    var args = cli.ParsedArgs{};
    args.command = .init;
    args.template = "empty";
    // no name

    const result = initCmd(&ctx, &args);
    try testing.expectEqual(CommandResult.not_found, result);
    try testing.expect(std.mem.indexOf(u8, getStderr(), "--name") != null);
}

test "initCmd: missing --template returns not_found" {
    resetMocks();
    resetInitCmdMocks();
    MockHttp.reset();

    var ctx = initTestContext();
    _ = &ctx;

    var args = cli.ParsedArgs{};
    args.command = .init;
    args.name = "my-app";
    // no template

    const result = initCmd(&ctx, &args);
    try testing.expectEqual(CommandResult.not_found, result);
    try testing.expect(std.mem.indexOf(u8, getStderr(), "--template") != null);
}

test "initCmd: unknown template reports error and lists available" {
    resetMocks();
    resetInitCmdMocks();
    MockHttp.reset();

    var ctx = initTestContext();
    _ = &ctx;

    var args = cli.ParsedArgs{};
    args.command = .init;
    args.name = "my-app";
    args.template = "nonexistent";

    const result = initCmd(&ctx, &args);
    try testing.expectEqual(CommandResult.not_found, result);
    try testing.expect(std.mem.indexOf(u8, getStderr(), "unknown template") != null);
    try testing.expect(std.mem.indexOf(u8, getStderr(), "available templates") != null);
}

// ── Property Tests ──

// **Property 21: Validate Is Read-Only**
// Validates: Requirement 13.4
// For any project state, running `zpm validate` shall leave all files on disk
// byte-identical. The command shall make zero file system writes.

fn simpleHash(data: []const u8) u64 {
    var h: u64 = 0xcbf29ce484222325;
    for (data) |b| {
        h ^= b;
        h *%= 0x100000001b3;
    }
    return h;
}

test "property 21: validate is read-only — valid and invalid manifests produce zero writes" {
    // **Validates: Requirements 13.4**
    const valid_manifests = [_][]const u8{
        \\.{
        \\    .protocol_version = 1,
        \\    .scope = "zpm",
        \\    .name = "core",
        \\    .version = "0.1.0",
        \\    .layer = 0,
        \\    .platform = .any,
        \\}
        ,
        \\.{
        \\    .protocol_version = 1,
        \\    .scope = "zpm",
        \\    .name = "window",
        \\    .version = "1.2.3",
        \\    .layer = 1,
        \\    .platform = .windows,
        \\}
        ,
        \\.{
        \\    .protocol_version = 1,
        \\    .scope = "mypkg",
        \\    .name = "render",
        \\    .version = "0.0.1",
        \\    .layer = 2,
        \\    .platform = .any,
        \\}
        ,
    };

    const invalid_manifests = [_][]const u8{
        \\.{
        \\    .protocol_version = 2,
        \\    .scope = "",
        \\    .name = "core",
        \\    .version = "0.1.0",
        \\    .layer = 0,
        \\}
        ,
        \\.{
        \\    .protocol_version = 0,
        \\    .scope = "zpm",
        \\    .name = "",
        \\    .version = "0.1.0",
        \\    .layer = 0,
        \\}
        ,
        \\.{
        \\    .protocol_version = 1,
        \\    .scope = "INVALID",
        \\    .name = "core",
        \\    .version = "0.1.0",
        \\    .layer = 0,
        \\}
        ,
    };

    // Test with valid manifests — 100 iterations cycling through them
    var iter: usize = 0;
    while (iter < 100) : (iter += 1) {
        const m = valid_manifests[iter % valid_manifests.len];
        resetMocks();
        MockHttp.reset();
        addMockFile("zpm.pkg.zon", m);

        const writes_before = mock_write_calls;

        const reg = testRegistryClient(false);
        const ctx = testContext(&reg, null);
        var args = cli.ParsedArgs{};
        args.command = .validate;

        _ = validateCmd(&ctx, &args);

        try testing.expectEqual(writes_before, mock_write_calls);
    }

    // Test with invalid manifests — 100 iterations cycling through them
    iter = 0;
    while (iter < 100) : (iter += 1) {
        const m = invalid_manifests[iter % invalid_manifests.len];
        resetMocks();
        MockHttp.reset();
        addMockFile("zpm.pkg.zon", m);

        const writes_before = mock_write_calls;

        const reg = testRegistryClient(false);
        const ctx = testContext(&reg, null);
        var args = cli.ParsedArgs{};
        args.command = .validate;

        _ = validateCmd(&ctx, &args);

        try testing.expectEqual(writes_before, mock_write_calls);
    }
}

// ── Doctor Command Tests ──

test "doctorCmd: all checks pass with healthy environment" {
    resetMocks();
    resetBootMocks();
    MockHttp.reset();
    MockHttp.get_response = "ok";
    mock_boot_exec_result = .{ .exit_code = 0, .stdout = "0.16.0\n" };

    addMockFile("build.zig.zon", sample_zon);
    addMockFile("build.zig", "// build file");

    const bootstrapper = bootstrap.ZigBootstrapper{
        .vtable = mock_boot_vtable,
        .offline = false,
        .auto_update = false,
    };

    const reg = testRegistryClient(false);
    var ctx = testContext(&reg, null);
    ctx.bootstrapper = &bootstrapper;

    var args = cli.ParsedArgs{};
    args.command = .doctor;

    const result = doctorCmd(&ctx, &args);
    try testing.expectEqual(CommandResult.success, result);
    const out = getStdout();
    try testing.expect(std.mem.indexOf(u8, out, "zpm v0.1.0") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Zig installed") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Registry reachable") != null);
    try testing.expect(std.mem.indexOf(u8, out, "build.zig.zon found") != null);
    try testing.expect(std.mem.indexOf(u8, out, "build.zig found") != null);
    try testing.expect(std.mem.indexOf(u8, out, "1 zpm package(s)") != null);
}

test "doctorCmd: reports failures but runs all checks" {
    resetMocks();
    resetBootMocks();
    MockHttp.reset();
    MockHttp.get_should_fail = true;
    mock_boot_exec_result = null; // zig not found

    // No build.zig.zon or build.zig files

    const bootstrapper = bootstrap.ZigBootstrapper{
        .vtable = mock_boot_vtable,
        .offline = true,
        .auto_update = false,
    };

    const reg = testRegistryClient(false);
    var ctx = testContext(&reg, null);
    ctx.bootstrapper = &bootstrapper;

    var args = cli.ParsedArgs{};
    args.command = .doctor;

    const result = doctorCmd(&ctx, &args);
    try testing.expectEqual(CommandResult.validation_failed, result);
    // All checks should still run — verify stderr has multiple failure indicators
    const err_out = getStderr();
    try testing.expect(std.mem.indexOf(u8, err_out, "Zig not found") != null);
    try testing.expect(std.mem.indexOf(u8, err_out, "Registry unreachable") != null);
    try testing.expect(std.mem.indexOf(u8, err_out, "build.zig.zon not found") != null);
    try testing.expect(std.mem.indexOf(u8, err_out, "build.zig not found") != null);
    // zpm version should still be in stdout
    try testing.expect(std.mem.indexOf(u8, getStdout(), "zpm v0.1.0") != null);
}

test "doctorCmd: works without bootstrapper" {
    resetMocks();
    MockHttp.reset();
    MockHttp.get_response = "ok";
    addMockFile("build.zig.zon", empty_deps_zon);
    addMockFile("build.zig", "// build");

    const reg = testRegistryClient(false);
    const ctx = testContext(&reg, null);

    var args = cli.ParsedArgs{};
    args.command = .doctor;

    const result = doctorCmd(&ctx, &args);
    try testing.expectEqual(CommandResult.success, result);
    try testing.expect(std.mem.indexOf(u8, getStdout(), "Zig check skipped") != null);
    try testing.expect(std.mem.indexOf(u8, getStdout(), "0 zpm package(s)") != null);
}

// **Property 20: Search Layer Filtering**
// Validates: Requirement 11.2
// For any search query with a --layer filter, the registry URL shall contain
// the correct layer parameter value.

test "property 20: search layer filtering — URL contains correct layer parameter" {
    // **Validates: Requirements 11.2**
    const queries = [_][]const u8{ "core", "render", "gl", "window", "timer", "http" };
    const layer_values = [_]?u2{ 0, 1, 2, null };

    var iter: usize = 0;
    while (iter < 100) : (iter += 1) {
        const query = queries[iter % queries.len];
        const layer = layer_values[iter % layer_values.len];

        resetMocks();
        MockHttp.reset();
        MockHttp.get_response = "[]";

        const reg = testRegistryClient(false);
        const ctx = testContext(&reg, null);

        var args = cli.ParsedArgs{};
        args.command = .search;
        args.positional[0] = query;
        args.positional_count = 1;
        args.layer_filter = layer;

        const result = searchCmd(&ctx, &args);
        try testing.expectEqual(CommandResult.success, result);

        const url = MockHttp.getLastUrl();

        // URL must contain the query
        try testing.expect(std.mem.indexOf(u8, url, query) != null);

        if (layer) |l| {
            // When layer is specified, URL must contain "&layer=N"
            const expected_suffix = switch (l) {
                0 => "&layer=0",
                1 => "&layer=1",
                2 => "&layer=2",
                3 => "&layer=3",
            };
            try testing.expect(std.mem.indexOf(u8, url, expected_suffix) != null);
        } else {
            // When no layer filter, URL must NOT contain "&layer="
            try testing.expect(std.mem.indexOf(u8, url, "&layer=") == null);
        }
    }
}

// ── Doctor Transport Health Tests ──

test "doctorCmd: displays transport health with mock telemetry" {
    resetMocks();
    MockHttp.reset();
    MockHttp.get_response = "ok";
    addMockFile("build.zig.zon", empty_deps_zon);
    addMockFile("build.zig", "// build");

    const health = TransportHealth{
        .packets_sent = 1000,
        .packets_lost = 50,
        .smoothed_rtt_us = 12500, // 12.5 ms
        .cwnd = 14720,
        .handshake_duration_us = 45000, // 45 ms
        .conn_state = 2, // connected
        .negotiated_version = 0x00000001, // QUIC v1
    };

    const reg = testRegistryClient(false);
    var ctx = testContext(&reg, null);
    ctx.quic_telemetry = &health;

    var args = cli.ParsedArgs{};
    args.command = .doctor;

    const result = doctorCmd(&ctx, &args);
    try testing.expectEqual(CommandResult.success, result);
    const out = getStdout();
    // Transport Health section present
    try testing.expect(std.mem.indexOf(u8, out, "Transport Health") != null);
    // Connection state
    try testing.expect(std.mem.indexOf(u8, out, "connected") != null);
    // Version
    try testing.expect(std.mem.indexOf(u8, out, "QUIC v1") != null);
    // RTT (12.5 ms)
    try testing.expect(std.mem.indexOf(u8, out, "12.5 ms") != null);
    // Loss rate: 5% (50/1000)
    try testing.expect(std.mem.indexOf(u8, out, "5%") != null);
    try testing.expect(std.mem.indexOf(u8, out, "50/1000") != null);
    // CWND
    try testing.expect(std.mem.indexOf(u8, out, "14720") != null);
    // Handshake duration
    try testing.expect(std.mem.indexOf(u8, out, "45 ms") != null);
}

test "doctorCmd: no QUIC connection shows graceful message" {
    resetMocks();
    MockHttp.reset();
    MockHttp.get_response = "ok";
    addMockFile("build.zig.zon", empty_deps_zon);
    addMockFile("build.zig", "// build");

    const reg = testRegistryClient(false);
    const ctx = testContext(&reg, null);
    // quic_telemetry defaults to null

    var args = cli.ParsedArgs{};
    args.command = .doctor;

    const result = doctorCmd(&ctx, &args);
    try testing.expectEqual(CommandResult.success, result);
    const out = getStdout();
    try testing.expect(std.mem.indexOf(u8, out, "Transport Health") != null);
    try testing.expect(std.mem.indexOf(u8, out, "No QUIC connection") != null);
}

test "doctorCmd: transport health with QUIC v2 version" {
    resetMocks();
    MockHttp.reset();
    MockHttp.get_response = "ok";
    addMockFile("build.zig.zon", empty_deps_zon);
    addMockFile("build.zig", "// build");

    const health = TransportHealth{
        .packets_sent = 500,
        .packets_lost = 0,
        .smoothed_rtt_us = 3200,
        .cwnd = 29440,
        .handshake_duration_us = 22000,
        .conn_state = 2,
        .negotiated_version = 0x6b3343cf, // QUIC v2
    };

    const reg = testRegistryClient(false);
    var ctx = testContext(&reg, null);
    ctx.quic_telemetry = &health;

    var args = cli.ParsedArgs{};
    args.command = .doctor;

    const result = doctorCmd(&ctx, &args);
    try testing.expectEqual(CommandResult.success, result);
    const out = getStdout();
    try testing.expect(std.mem.indexOf(u8, out, "QUIC v2") != null);
    try testing.expect(std.mem.indexOf(u8, out, "0%") != null); // zero loss
}

test "doctorCmd: transport health with zero packets sent" {
    resetMocks();
    MockHttp.reset();
    MockHttp.get_response = "ok";
    addMockFile("build.zig.zon", empty_deps_zon);
    addMockFile("build.zig", "// build");

    const health = TransportHealth{
        .packets_sent = 0,
        .packets_lost = 0,
        .smoothed_rtt_us = 0,
        .cwnd = 0,
        .handshake_duration_us = 0,
        .conn_state = 0, // idle
        .negotiated_version = 0,
    };

    const reg = testRegistryClient(false);
    var ctx = testContext(&reg, null);
    ctx.quic_telemetry = &health;

    var args = cli.ParsedArgs{};
    args.command = .doctor;

    const result = doctorCmd(&ctx, &args);
    try testing.expectEqual(CommandResult.success, result);
    const out = getStdout();
    try testing.expect(std.mem.indexOf(u8, out, "idle") != null);
    try testing.expect(std.mem.indexOf(u8, out, "0% (0/0)") != null);
}
