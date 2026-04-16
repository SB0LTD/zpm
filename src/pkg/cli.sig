// Layer 0 — Pure argument parsing and command dispatch for the zpm CLI.
// No I/O, no allocator. Operates on a slice of argument strings.
//
// Parses commands, aliases, global flags, command-specific flags,
// and positional arguments. Reports unknown commands/flags with
// closest-match suggestions via simple edit distance.

// ── Public Types ──

pub const Command = enum {
    init,
    install,
    uninstall,
    list,
    search,
    publish,
    validate,
    update,
    doctor,
    run,
    build,
    help,
    version,
};

pub const GlobalFlags = struct {
    verbose: bool = false,
    quiet: bool = false,
    offline: bool = false,
    registry_url: ?[]const u8 = null,
    help: bool = false,
    show_version: bool = false,
};

const max_positional = 16;

pub const ParsedArgs = struct {
    command: ?Command = null,
    flags: GlobalFlags = .{},
    positional: [max_positional][]const u8 = undefined,
    positional_count: usize = 0,
    // Command-specific flags
    template: ?[]const u8 = null, // --template for init
    name: ?[]const u8 = null, // --name for init
    dry_run: bool = false, // --dry-run for publish
    layer_filter: ?u2 = null, // --layer for search
    force: bool = false, // --force for init
    yes: bool = false, // --yes for auto-confirm
    transport: ?[]const u8 = null, // --transport for transport selection
};

pub const ParseResult = union(enum) {
    ok: ParsedArgs,
    err: ParseErrorInfo,
};

// ── Command and Alias Tables ──

const CommandEntry = struct {
    name: []const u8,
    cmd: Command,
};

const commands = [_]CommandEntry{
    .{ .name = "init", .cmd = .init },
    .{ .name = "install", .cmd = .install },
    .{ .name = "uninstall", .cmd = .uninstall },
    .{ .name = "list", .cmd = .list },
    .{ .name = "search", .cmd = .search },
    .{ .name = "publish", .cmd = .publish },
    .{ .name = "validate", .cmd = .validate },
    .{ .name = "update", .cmd = .update },
    .{ .name = "doctor", .cmd = .doctor },
    .{ .name = "run", .cmd = .run },
    .{ .name = "build", .cmd = .build },
};

const aliases = [_]CommandEntry{
    .{ .name = "i", .cmd = .install },
    .{ .name = "rm", .cmd = .uninstall },
    .{ .name = "ls", .cmd = .list },
    .{ .name = "pub", .cmd = .publish },
    .{ .name = "val", .cmd = .validate },
    .{ .name = "up", .cmd = .update },
};

// ── Public API ──

/// Parse a slice of CLI argument strings into a structured result.
/// The slice should NOT include the program name (argv[0]).
pub fn parse(args: []const []const u8) ParseResult {
    var result = ParsedArgs{};
    var i: usize = 0;

    while (i < args.len) {
        const arg = args[i];

        if (arg.len == 0) {
            i += 1;
            continue;
        }

        // Flags start with '-'
        if (arg.len >= 2 and arg[0] == '-') {
            const flag_result = parseFlag(arg, args, i, &result);
            switch (flag_result) {
                .advance => |adv| {
                    i += adv;
                    continue;
                },
                .err => |e| return .{ .err = e },
            }
        }

        // Not a flag — try to parse as command (if we don't have one yet)
        if (result.command == null) {
            if (lookupCommand(arg)) |cmd| {
                result.command = cmd;
                i += 1;
                continue;
            }
            // Unknown command
            return .{ .err = .{
                .message = "unknown command",
                .suggestion = findClosestCommand(arg),
            } };
        }

        // Already have a command — this is a positional arg
        if (result.positional_count < max_positional) {
            result.positional[result.positional_count] = arg;
            result.positional_count += 1;
        }
        i += 1;
    }

    // Post-processing: --help alone with no command → help command
    if (result.flags.help and result.command == null) {
        result.command = .help;
        result.flags.help = false;
    }

    // --version alone with no command → version command
    if (result.flags.show_version and result.command == null) {
        result.command = .version;
        result.flags.show_version = false;
    }

    // Empty args → help
    if (result.command == null) {
        result.command = .help;
    }

    return .{ .ok = result };
}

// ── Flag Parsing ──

pub const ParseErrorInfo = struct {
    message: []const u8,
    suggestion: ?[]const u8, // closest match for unknown command
};

const FlagResult = union(enum) {
    advance: usize, // how many args to skip (including current)
    err: ParseErrorInfo,
};

fn parseFlag(
    arg: []const u8,
    args: []const []const u8,
    i: usize,
    result: *ParsedArgs,
) FlagResult {
    // Long flags
    if (arg.len >= 3 and arg[0] == '-' and arg[1] == '-') {
        const flag_name = arg[2..];

        if (strEql(flag_name, "verbose")) {
            result.flags.verbose = true;
            return .{ .advance = 1 };
        }
        if (strEql(flag_name, "quiet")) {
            result.flags.quiet = true;
            return .{ .advance = 1 };
        }
        if (strEql(flag_name, "offline")) {
            result.flags.offline = true;
            return .{ .advance = 1 };
        }
        if (strEql(flag_name, "help")) {
            result.flags.help = true;
            return .{ .advance = 1 };
        }
        if (strEql(flag_name, "version")) {
            result.flags.show_version = true;
            return .{ .advance = 1 };
        }
        if (strEql(flag_name, "registry")) {
            if (i + 1 >= args.len) {
                return .{ .err = .{
                    .message = "missing value for --registry",
                    .suggestion = null,
                } };
            }
            result.flags.registry_url = args[i + 1];
            return .{ .advance = 2 };
        }
        // Command-specific flags
        if (strEql(flag_name, "template")) {
            if (i + 1 >= args.len) {
                return .{ .err = .{
                    .message = "missing value for --template",
                    .suggestion = null,
                } };
            }
            result.template = args[i + 1];
            return .{ .advance = 2 };
        }
        if (strEql(flag_name, "name")) {
            if (i + 1 >= args.len) {
                return .{ .err = .{
                    .message = "missing value for --name",
                    .suggestion = null,
                } };
            }
            result.name = args[i + 1];
            return .{ .advance = 2 };
        }
        if (strEql(flag_name, "dry-run")) {
            result.dry_run = true;
            return .{ .advance = 1 };
        }
        if (strEql(flag_name, "layer")) {
            if (i + 1 >= args.len) {
                return .{ .err = .{
                    .message = "missing value for --layer",
                    .suggestion = null,
                } };
            }
            const val = args[i + 1];
            if (val.len == 1 and val[0] >= '0' and val[0] <= '2') {
                result.layer_filter = @intCast(val[0] - '0');
                return .{ .advance = 2 };
            }
            return .{ .err = .{
                .message = "invalid value for --layer (must be 0, 1, or 2)",
                .suggestion = null,
            } };
        }
        if (strEql(flag_name, "force")) {
            result.force = true;
            return .{ .advance = 1 };
        }
        if (strEql(flag_name, "yes")) {
            result.yes = true;
            return .{ .advance = 1 };
        }
        if (strEql(flag_name, "transport")) {
            if (i + 1 >= args.len) {
                return .{ .err = .{
                    .message = "missing value for --transport",
                    .suggestion = null,
                } };
            }
            result.transport = args[i + 1];
            return .{ .advance = 2 };
        }

        // Unknown long flag
        return .{ .err = .{
            .message = "unknown flag",
            .suggestion = findClosestFlag(flag_name),
        } };
    }

    // Short flags (single '-')
    if (arg.len == 2 and arg[0] == '-') {
        const c = arg[1];
        if (c == 'v') {
            result.flags.verbose = true;
            return .{ .advance = 1 };
        }
        if (c == 'q') {
            result.flags.quiet = true;
            return .{ .advance = 1 };
        }
        if (c == 'h') {
            result.flags.help = true;
            return .{ .advance = 1 };
        }
        if (c == 'V') {
            result.flags.show_version = true;
            return .{ .advance = 1 };
        }
        if (c == 'y') {
            result.yes = true;
            return .{ .advance = 1 };
        }

        // Unknown short flag
        return .{ .err = .{
            .message = "unknown flag",
            .suggestion = null,
        } };
    }

    // Bare '-' or other patterns — treat as unknown flag
    return .{ .err = .{
        .message = "unknown flag",
        .suggestion = null,
    } };
}

// ── Command Lookup ──

fn lookupCommand(name: []const u8) ?Command {
    // Check exact commands first
    for (commands) |entry| {
        if (strEql(name, entry.name)) return entry.cmd;
    }
    // Check aliases
    for (aliases) |entry| {
        if (strEql(name, entry.name)) return entry.cmd;
    }
    return null;
}

// ── Suggestion Engine (Levenshtein-like distance) ──

/// Find the closest command name to the given unknown input.
/// Returns null if no command is close enough (distance > 3).
fn findClosestCommand(input: []const u8) ?[]const u8 {
    var best: ?[]const u8 = null;
    var best_dist: usize = 4; // threshold: only suggest if distance <= 3

    for (commands) |entry| {
        const d = editDistance(input, entry.name);
        if (d < best_dist) {
            best_dist = d;
            best = entry.name;
        }
    }
    for (aliases) |entry| {
        const d = editDistance(input, entry.name);
        if (d < best_dist) {
            best_dist = d;
            best = entry.name;
        }
    }
    return best;
}

const known_flags = [_][]const u8{
    "verbose",
    "quiet",
    "offline",
    "help",
    "version",
    "registry",
    "template",
    "name",
    "dry-run",
    "layer",
    "force",
    "yes",
    "transport",
};

fn findClosestFlag(input: []const u8) ?[]const u8 {
    var best: ?[]const u8 = null;
    var best_dist: usize = 4;

    for (known_flags) |flag| {
        const d = editDistance(input, flag);
        if (d < best_dist) {
            best_dist = d;
            best = flag;
        }
    }
    return best;
}

/// Simple Levenshtein edit distance. Bounded to max_len 32 to keep
/// stack usage fixed. Returns max_len+1 if either string is too long.
fn editDistance(a: []const u8, b: []const u8) usize {
    const max_len = 32;
    if (a.len > max_len or b.len > max_len) return max_len + 1;

    var prev: [max_len + 1]usize = undefined;
    var curr: [max_len + 1]usize = undefined;

    for (0..b.len + 1) |j| {
        prev[j] = j;
    }

    for (a, 0..) |ca, i| {
        curr[0] = i + 1;
        for (b, 0..) |cb, j| {
            const cost: usize = if (ca == cb) 0 else 1;
            const del = prev[j + 1] + 1;
            const ins = curr[j] + 1;
            const sub = prev[j] + cost;
            curr[j + 1] = @min(del, @min(ins, sub));
        }
        // Swap prev and curr
        const tmp = prev;
        prev = curr;
        curr = tmp;
    }

    return prev[b.len];
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

// ── Helper ──

fn expectOk(result: ParseResult) !ParsedArgs {
    switch (result) {
        .ok => |args| return args,
        .err => |e| {
            std.debug.print("unexpected parse error: {s}\n", .{e.message});
            return error.TestUnexpectedResult;
        },
    }
}

fn expectErr(result: ParseResult) !ParseErrorInfo {
    switch (result) {
        .ok => {
            std.debug.print("expected parse error but got ok\n", .{});
            return error.TestUnexpectedResult;
        },
        .err => |e| return e,
    }
}

// ── Command Parsing ──

test "parse: each command parsed correctly" {
    const cmds = [_]struct { name: []const u8, expected: Command }{
        .{ .name = "init", .expected = .init },
        .{ .name = "install", .expected = .install },
        .{ .name = "uninstall", .expected = .uninstall },
        .{ .name = "list", .expected = .list },
        .{ .name = "search", .expected = .search },
        .{ .name = "publish", .expected = .publish },
        .{ .name = "validate", .expected = .validate },
        .{ .name = "update", .expected = .update },
        .{ .name = "doctor", .expected = .doctor },
        .{ .name = "run", .expected = .run },
        .{ .name = "build", .expected = .build },
    };
    for (cmds) |c| {
        const args = [_][]const u8{c.name};
        const parsed = try expectOk(parse(&args));
        try testing.expectEqual(c.expected, parsed.command.?);
    }
}

// ── Alias Resolution ──

test "parse: each alias resolved correctly" {
    const alias_tests = [_]struct { alias: []const u8, expected: Command }{
        .{ .alias = "i", .expected = .install },
        .{ .alias = "rm", .expected = .uninstall },
        .{ .alias = "ls", .expected = .list },
        .{ .alias = "pub", .expected = .publish },
        .{ .alias = "val", .expected = .validate },
        .{ .alias = "up", .expected = .update },
    };
    for (alias_tests) |a| {
        const args = [_][]const u8{a.alias};
        const parsed = try expectOk(parse(&args));
        try testing.expectEqual(a.expected, parsed.command.?);
    }
}

// ── Global Flags ──

test "parse: --verbose flag" {
    const args = [_][]const u8{ "--verbose", "install" };
    const parsed = try expectOk(parse(&args));
    try testing.expect(parsed.flags.verbose);
    try testing.expectEqual(Command.install, parsed.command.?);
}

test "parse: -v short flag" {
    const args = [_][]const u8{ "-v", "build" };
    const parsed = try expectOk(parse(&args));
    try testing.expect(parsed.flags.verbose);
}

test "parse: --quiet flag" {
    const args = [_][]const u8{ "install", "--quiet", "@zpm/core" };
    const parsed = try expectOk(parse(&args));
    try testing.expect(parsed.flags.quiet);
    try testing.expectEqual(Command.install, parsed.command.?);
}

test "parse: -q short flag" {
    const args = [_][]const u8{ "-q", "list" };
    const parsed = try expectOk(parse(&args));
    try testing.expect(parsed.flags.quiet);
}

test "parse: --offline flag" {
    const args = [_][]const u8{ "--offline", "install", "@zpm/core" };
    const parsed = try expectOk(parse(&args));
    try testing.expect(parsed.flags.offline);
}

test "parse: --registry flag with value" {
    const args = [_][]const u8{ "--registry", "https://my-registry.dev", "install", "@zpm/core" };
    const parsed = try expectOk(parse(&args));
    try testing.expectEqualStrings("https://my-registry.dev", parsed.flags.registry_url.?);
    try testing.expectEqual(Command.install, parsed.command.?);
}

test "parse: --help alone becomes help command" {
    const args = [_][]const u8{"--help"};
    const parsed = try expectOk(parse(&args));
    try testing.expectEqual(Command.help, parsed.command.?);
    try testing.expect(!parsed.flags.help); // consumed into command
}

test "parse: -h alone becomes help command" {
    const args = [_][]const u8{"-h"};
    const parsed = try expectOk(parse(&args));
    try testing.expectEqual(Command.help, parsed.command.?);
}

test "parse: --help with command sets help flag" {
    const args = [_][]const u8{ "install", "--help" };
    const parsed = try expectOk(parse(&args));
    try testing.expectEqual(Command.install, parsed.command.?);
    try testing.expect(parsed.flags.help);
}

test "parse: --version alone becomes version command" {
    const args = [_][]const u8{"--version"};
    const parsed = try expectOk(parse(&args));
    try testing.expectEqual(Command.version, parsed.command.?);
    try testing.expect(!parsed.flags.show_version); // consumed into command
}

test "parse: -V alone becomes version command" {
    const args = [_][]const u8{"-V"};
    const parsed = try expectOk(parse(&args));
    try testing.expectEqual(Command.version, parsed.command.?);
}

// ── Command-Specific Flags ──

test "parse: --template flag for init" {
    const args = [_][]const u8{ "init", "--template", "gl-app" };
    const parsed = try expectOk(parse(&args));
    try testing.expectEqual(Command.init, parsed.command.?);
    try testing.expectEqualStrings("gl-app", parsed.template.?);
}

test "parse: --name flag for init" {
    const args = [_][]const u8{ "init", "--name", "my-project" };
    const parsed = try expectOk(parse(&args));
    try testing.expectEqual(Command.init, parsed.command.?);
    try testing.expectEqualStrings("my-project", parsed.name.?);
}

test "parse: --dry-run flag for publish" {
    const args = [_][]const u8{ "publish", "--dry-run" };
    const parsed = try expectOk(parse(&args));
    try testing.expectEqual(Command.publish, parsed.command.?);
    try testing.expect(parsed.dry_run);
}

test "parse: --layer flag for search" {
    const args = [_][]const u8{ "search", "window", "--layer", "1" };
    const parsed = try expectOk(parse(&args));
    try testing.expectEqual(Command.search, parsed.command.?);
    try testing.expectEqual(@as(u2, 1), parsed.layer_filter.?);
}

test "parse: --force flag for init" {
    const args = [_][]const u8{ "init", "--force" };
    const parsed = try expectOk(parse(&args));
    try testing.expectEqual(Command.init, parsed.command.?);
    try testing.expect(parsed.force);
}

test "parse: --yes flag for auto-confirm" {
    const args = [_][]const u8{ "update", "--yes" };
    const parsed = try expectOk(parse(&args));
    try testing.expectEqual(Command.update, parsed.command.?);
    try testing.expect(parsed.yes);
}

test "parse: -y short flag for auto-confirm" {
    const args = [_][]const u8{ "update", "-y" };
    const parsed = try expectOk(parse(&args));
    try testing.expect(parsed.yes);
}

// ── Positional Args ──

test "parse: positional args captured for install" {
    const args = [_][]const u8{ "install", "@zpm/core", "@zpm/window" };
    const parsed = try expectOk(parse(&args));
    try testing.expectEqual(Command.install, parsed.command.?);
    try testing.expectEqual(@as(usize, 2), parsed.positional_count);
    try testing.expectEqualStrings("@zpm/core", parsed.positional[0]);
    try testing.expectEqualStrings("@zpm/window", parsed.positional[1]);
}

test "parse: positional args captured for uninstall" {
    const args = [_][]const u8{ "rm", "@zpm/core" };
    const parsed = try expectOk(parse(&args));
    try testing.expectEqual(Command.uninstall, parsed.command.?);
    try testing.expectEqual(@as(usize, 1), parsed.positional_count);
    try testing.expectEqualStrings("@zpm/core", parsed.positional[0]);
}

test "parse: positional args for search query" {
    const args = [_][]const u8{ "search", "chart" };
    const parsed = try expectOk(parse(&args));
    try testing.expectEqual(Command.search, parsed.command.?);
    try testing.expectEqual(@as(usize, 1), parsed.positional_count);
    try testing.expectEqualStrings("chart", parsed.positional[0]);
}

// ── Error Cases ──

test "parse: unknown command returns error with suggestion" {
    const args = [_][]const u8{"instal"};
    const err = try expectErr(parse(&args));
    try testing.expectEqualStrings("unknown command", err.message);
    try testing.expectEqualStrings("install", err.suggestion.?);
}

test "parse: unknown command with no close match" {
    const args = [_][]const u8{"zzzzzzzzz"};
    const err = try expectErr(parse(&args));
    try testing.expectEqualStrings("unknown command", err.message);
    try testing.expect(err.suggestion == null);
}

test "parse: unknown flag returns error" {
    const args = [_][]const u8{ "install", "--foobar" };
    const err = try expectErr(parse(&args));
    try testing.expectEqualStrings("unknown flag", err.message);
}

test "parse: unknown flag with close match suggests" {
    const args = [_][]const u8{ "install", "--verbos" };
    const err = try expectErr(parse(&args));
    try testing.expectEqualStrings("unknown flag", err.message);
    try testing.expectEqualStrings("verbose", err.suggestion.?);
}

test "parse: missing --registry value returns error" {
    const args = [_][]const u8{ "install", "--registry" };
    const err = try expectErr(parse(&args));
    try testing.expectEqualStrings("missing value for --registry", err.message);
}

test "parse: missing --template value returns error" {
    const args = [_][]const u8{ "init", "--template" };
    const err = try expectErr(parse(&args));
    try testing.expectEqualStrings("missing value for --template", err.message);
}

test "parse: missing --name value returns error" {
    const args = [_][]const u8{ "init", "--name" };
    const err = try expectErr(parse(&args));
    try testing.expectEqualStrings("missing value for --name", err.message);
}

test "parse: missing --layer value returns error" {
    const args = [_][]const u8{ "search", "--layer" };
    const err = try expectErr(parse(&args));
    try testing.expectEqualStrings("missing value for --layer", err.message);
}

test "parse: invalid --layer value returns error" {
    const args = [_][]const u8{ "search", "--layer", "5" };
    const err = try expectErr(parse(&args));
    try testing.expectEqualStrings("invalid value for --layer (must be 0, 1, or 2)", err.message);
}

// ── Empty Args ──

test "parse: empty args returns help" {
    const args = [_][]const u8{};
    const parsed = try expectOk(parse(&args));
    try testing.expectEqual(Command.help, parsed.command.?);
}

// ── Flags Before and After Command ──

test "parse: global flags before command" {
    const args = [_][]const u8{ "--verbose", "--offline", "install", "@zpm/core" };
    const parsed = try expectOk(parse(&args));
    try testing.expect(parsed.flags.verbose);
    try testing.expect(parsed.flags.offline);
    try testing.expectEqual(Command.install, parsed.command.?);
    try testing.expectEqual(@as(usize, 1), parsed.positional_count);
}

test "parse: global flags after command" {
    const args = [_][]const u8{ "install", "@zpm/core", "--verbose", "--offline" };
    const parsed = try expectOk(parse(&args));
    try testing.expect(parsed.flags.verbose);
    try testing.expect(parsed.flags.offline);
    try testing.expectEqual(Command.install, parsed.command.?);
    try testing.expectEqual(@as(usize, 1), parsed.positional_count);
}

test "parse: mixed flags and positional args" {
    const args = [_][]const u8{ "--verbose", "install", "@zpm/core", "--offline", "@zpm/window" };
    const parsed = try expectOk(parse(&args));
    try testing.expect(parsed.flags.verbose);
    try testing.expect(parsed.flags.offline);
    try testing.expectEqual(Command.install, parsed.command.?);
    try testing.expectEqual(@as(usize, 2), parsed.positional_count);
    try testing.expectEqualStrings("@zpm/core", parsed.positional[0]);
    try testing.expectEqualStrings("@zpm/window", parsed.positional[1]);
}

// ── Combined Flags ──

test "parse: init with --template and --name non-interactive" {
    const args = [_][]const u8{ "init", "--template", "gl-app", "--name", "my-app", "--force" };
    const parsed = try expectOk(parse(&args));
    try testing.expectEqual(Command.init, parsed.command.?);
    try testing.expectEqualStrings("gl-app", parsed.template.?);
    try testing.expectEqualStrings("my-app", parsed.name.?);
    try testing.expect(parsed.force);
}

test "parse: publish with --dry-run and --verbose" {
    const args = [_][]const u8{ "pub", "--dry-run", "--verbose" };
    const parsed = try expectOk(parse(&args));
    try testing.expectEqual(Command.publish, parsed.command.?);
    try testing.expect(parsed.dry_run);
    try testing.expect(parsed.flags.verbose);
}

// ── Edit Distance ──

test "editDistance: identical strings" {
    try testing.expectEqual(@as(usize, 0), editDistance("install", "install"));
}

test "editDistance: one char difference" {
    try testing.expectEqual(@as(usize, 1), editDistance("instal", "install"));
}

test "editDistance: completely different" {
    try testing.expect(editDistance("abc", "xyz") > 0);
}

test "editDistance: empty strings" {
    try testing.expectEqual(@as(usize, 0), editDistance("", ""));
    try testing.expectEqual(@as(usize, 3), editDistance("abc", ""));
    try testing.expectEqual(@as(usize, 3), editDistance("", "abc"));
}
