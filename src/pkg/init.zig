// Layer 0 — Project scaffolding for `zpm init`.
// Uses vtable for all filesystem I/O so the core logic is pure and testable.
//
// Requirements: 16.1, 16.2, 16.3, 16.4, 16.5, 16.6, 16.7, 16.8, 16.9, 16.10, 16.11

const std = @import("std");

// ── Public Types ──

pub const Template = enum {
    empty,
    window,
    gl_app,
    trading,
    package,
    cli_app,
    web_server,
    gui_app,
    library,

    pub fn fromString(s: []const u8) ?Template {
        const map = .{
            .{ "empty", Template.empty },
            .{ "window", Template.window },
            .{ "gl-app", Template.gl_app },
            .{ "gl_app", Template.gl_app },
            .{ "trading", Template.trading },
            .{ "package", Template.package },
            .{ "cli-app", Template.cli_app },
            .{ "cli_app", Template.cli_app },
            .{ "web-server", Template.web_server },
            .{ "web_server", Template.web_server },
            .{ "gui-app", Template.gui_app },
            .{ "gui_app", Template.gui_app },
            .{ "library", Template.library },
        };
        inline for (map) |entry| {
            if (strEql(s, entry[0])) return entry[1];
        }
        return null;
    }

    pub fn name(self: Template) []const u8 {
        return switch (self) {
            .empty => "empty",
            .window => "window",
            .gl_app => "gl-app",
            .trading => "trading",
            .package => "package",
            .cli_app => "cli-app",
            .web_server => "web-server",
            .gui_app => "gui-app",
            .library => "library",
        };
    }
};

pub const available_templates = [_][]const u8{
    "empty",   "window",     "gl-app",  "trading", "package",
    "cli-app", "web-server", "gui-app", "library",
};

pub const InitConfig = struct {
    project_name: []const u8,
    template: Template,
    force: bool = false,
    package_layer: ?u2 = null,
};

pub const InitVtable = struct {
    create_dir: *const fn (path: []const u8) bool,
    write_file: *const fn (path: []const u8, content: []const u8) bool,
    dir_exists: *const fn (path: []const u8) bool,
    dir_is_empty: *const fn (path: []const u8) bool,
    remove_dir: *const fn (path: []const u8) bool,
    print: *const fn (msg: []const u8) void,
};

pub const InitResult = enum {
    success,
    dir_exists_not_empty,
    template_not_found,
    failed,
};

// ── Scaffold Function ──

pub fn scaffold(vtable: *const InitVtable, config: *const InitConfig) InitResult {
    const project = config.project_name;
    const tmpl = config.template;

    // Step 1: Check if target dir exists and not empty (reject unless --force)
    if (vtable.dir_exists(project)) {
        if (!vtable.dir_is_empty(project)) {
            if (!config.force) {
                vtable.print("directory exists and is not empty — use --force to overwrite\n");
                return .dir_exists_not_empty;
            }
            // Force: remove existing dir first
            if (!vtable.remove_dir(project)) {
                vtable.print("failed to remove existing directory\n");
                return .failed;
            }
        }
    }

    // Step 2: Create project directory
    if (!vtable.create_dir(project)) {
        vtable.print("failed to create project directory\n");
        return .failed;
    }

    // Step 3: Generate build.zig.zon
    var zon_buf: [4096]u8 = undefined;
    const zon_content = generateBuildZigZon(project, tmpl, &zon_buf) orelse {
        cleanup(vtable, project);
        return .failed;
    };
    if (!writeProjectFile(vtable, project, "build.zig.zon", zon_content)) {
        cleanup(vtable, project);
        return .failed;
    }

    // Step 4: Generate build.zig
    var build_buf: [8192]u8 = undefined;
    const build_content = generateBuildZig(project, tmpl, &build_buf) orelse {
        cleanup(vtable, project);
        return .failed;
    };
    if (!writeProjectFile(vtable, project, "build.zig", build_content)) {
        cleanup(vtable, project);
        return .failed;
    }

    // Step 5: Create src/ dir and generate src/main.zig (or src/root.zig for package)
    var src_path_buf: [512]u8 = undefined;
    const src_dir = joinPath(project, "src", &src_path_buf) orelse {
        cleanup(vtable, project);
        return .failed;
    };
    if (!vtable.create_dir(src_dir)) {
        cleanup(vtable, project);
        return .failed;
    }

    var main_buf: [4096]u8 = undefined;
    const src_filename = if (tmpl == .package or tmpl == .library) "src/root.zig" else "src/main.zig";
    const main_content = generateMainZig(project, tmpl, &main_buf) orelse {
        cleanup(vtable, project);
        return .failed;
    };
    if (!writeProjectFile(vtable, project, src_filename, main_content)) {
        cleanup(vtable, project);
        return .failed;
    }

    // Step 6: Generate .gitignore
    if (!writeProjectFile(vtable, project, ".gitignore", gitignore_content)) {
        cleanup(vtable, project);
        return .failed;
    }

    // Step 7: Generate README.md
    var readme_buf: [2048]u8 = undefined;
    const readme_content = generateReadme(project, tmpl, &readme_buf) orelse {
        cleanup(vtable, project);
        return .failed;
    };
    if (!writeProjectFile(vtable, project, "README.md", readme_content)) {
        cleanup(vtable, project);
        return .failed;
    }

    // Step 10: For package template, generate zpm.pkg.zon
    if (tmpl == .package) {
        var pkg_buf: [2048]u8 = undefined;
        const pkg_content = generateZpmPkgZon(project, config.package_layer orelse 0, &pkg_buf) orelse {
            cleanup(vtable, project);
            return .failed;
        };
        if (!writeProjectFile(vtable, project, "zpm.pkg.zon", pkg_content)) {
            cleanup(vtable, project);
            return .failed;
        }
    }

    return .success;
}

// ── Cleanup ──

fn cleanup(vtable: *const InitVtable, project: []const u8) void {
    _ = vtable.remove_dir(project);
    vtable.print("cleaned up partial directory\n");
}

// ── Path Helpers ──

fn joinPath(base: []const u8, child: []const u8, buf: *[512]u8) ?[]const u8 {
    const total = base.len + 1 + child.len;
    if (total > buf.len) return null;
    @memcpy(buf[0..base.len], base);
    buf[base.len] = '/';
    @memcpy(buf[base.len + 1 .. base.len + 1 + child.len], child);
    return buf[0..total];
}

fn writeProjectFile(vtable: *const InitVtable, project: []const u8, rel_path: []const u8, content: []const u8) bool {
    var path_buf: [512]u8 = undefined;
    const full_path = joinPath(project, rel_path, &path_buf) orelse return false;
    return vtable.write_file(full_path, content);
}

fn strEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (ca != cb) return false;
    }
    return true;
}

// ── Template Content Generators ──

/// Replace all occurrences of {{project_name}} in a template with the actual name.
fn replacePlaceholder(template: []const u8, project_name: []const u8, buf: []u8) ?[]const u8 {
    const placeholder = "{{project_name}}";
    var out_pos: usize = 0;
    var in_pos: usize = 0;

    while (in_pos < template.len) {
        // Check if placeholder starts here
        if (in_pos + placeholder.len <= template.len and
            strEql(template[in_pos .. in_pos + placeholder.len], placeholder))
        {
            if (out_pos + project_name.len > buf.len) return null;
            @memcpy(buf[out_pos .. out_pos + project_name.len], project_name);
            out_pos += project_name.len;
            in_pos += placeholder.len;
        } else {
            if (out_pos >= buf.len) return null;
            buf[out_pos] = template[in_pos];
            out_pos += 1;
            in_pos += 1;
        }
    }
    return buf[0..out_pos];
}

// ── build.zig.zon Generator ──

fn generateBuildZigZon(project_name: []const u8, tmpl: Template, buf: *[4096]u8) ?[]const u8 {
    const template_str = switch (tmpl) {
        .empty => build_zig_zon_empty,
        .window => build_zig_zon_window,
        .gl_app => build_zig_zon_gl_app,
        .trading => build_zig_zon_trading,
        .package => build_zig_zon_package,
        .cli_app => build_zig_zon_cli_app,
        .web_server => build_zig_zon_web_server,
        .gui_app => build_zig_zon_gui_app,
        .library => build_zig_zon_library,
    };
    return replacePlaceholder(template_str, project_name, buf);
}

const build_zig_zon_empty =
    \\.{
    \\    .name = .@"{{project_name}}",
    \\    .version = "0.1.0",
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

const build_zig_zon_window =
    \\.{
    \\    .name = .@"{{project_name}}",
    \\    .version = "0.1.0",
    \\    .minimum_zig_version = "0.16.0",
    \\    .dependencies = .{
    \\        .@"zpm-core" = .{
    \\            .url = "https://registry.zpm.dev/pkg/@zpm/core/0.1.0.tar.gz",
    \\            .hash = "1220placeholder",
    \\        },
    \\        .@"zpm-win32" = .{
    \\            .url = "https://registry.zpm.dev/pkg/@zpm/win32/0.1.0.tar.gz",
    \\            .hash = "1220placeholder",
    \\        },
    \\        .@"zpm-gl" = .{
    \\            .url = "https://registry.zpm.dev/pkg/@zpm/gl/0.1.0.tar.gz",
    \\            .hash = "1220placeholder",
    \\        },
    \\        .@"zpm-window" = .{
    \\            .url = "https://registry.zpm.dev/pkg/@zpm/window/0.1.0.tar.gz",
    \\            .hash = "1220placeholder",
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

const build_zig_zon_gl_app =
    \\.{
    \\    .name = .@"{{project_name}}",
    \\    .version = "0.1.0",
    \\    .minimum_zig_version = "0.16.0",
    \\    .dependencies = .{
    \\        .@"zpm-core" = .{
    \\            .url = "https://registry.zpm.dev/pkg/@zpm/core/0.1.0.tar.gz",
    \\            .hash = "1220placeholder",
    \\        },
    \\        .@"zpm-win32" = .{
    \\            .url = "https://registry.zpm.dev/pkg/@zpm/win32/0.1.0.tar.gz",
    \\            .hash = "1220placeholder",
    \\        },
    \\        .@"zpm-gl" = .{
    \\            .url = "https://registry.zpm.dev/pkg/@zpm/gl/0.1.0.tar.gz",
    \\            .hash = "1220placeholder",
    \\        },
    \\        .@"zpm-window" = .{
    \\            .url = "https://registry.zpm.dev/pkg/@zpm/window/0.1.0.tar.gz",
    \\            .hash = "1220placeholder",
    \\        },
    \\        .@"zpm-color" = .{
    \\            .url = "https://registry.zpm.dev/pkg/@zpm/color/0.1.0.tar.gz",
    \\            .hash = "1220placeholder",
    \\        },
    \\        .@"zpm-primitives" = .{
    \\            .url = "https://registry.zpm.dev/pkg/@zpm/primitives/0.1.0.tar.gz",
    \\            .hash = "1220placeholder",
    \\        },
    \\        .@"zpm-timer" = .{
    \\            .url = "https://registry.zpm.dev/pkg/@zpm/timer/0.1.0.tar.gz",
    \\            .hash = "1220placeholder",
    \\        },
    \\        .@"zpm-input" = .{
    \\            .url = "https://registry.zpm.dev/pkg/@zpm/input/0.1.0.tar.gz",
    \\            .hash = "1220placeholder",
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

const build_zig_zon_trading =
    \\.{
    \\    .name = .@"{{project_name}}",
    \\    .version = "0.1.0",
    \\    .minimum_zig_version = "0.16.0",
    \\    .dependencies = .{
    \\        .@"zpm-core" = .{
    \\            .url = "https://registry.zpm.dev/pkg/@zpm/core/0.1.0.tar.gz",
    \\            .hash = "1220placeholder",
    \\        },
    \\        .@"zpm-win32" = .{
    \\            .url = "https://registry.zpm.dev/pkg/@zpm/win32/0.1.0.tar.gz",
    \\            .hash = "1220placeholder",
    \\        },
    \\        .@"zpm-gl" = .{
    \\            .url = "https://registry.zpm.dev/pkg/@zpm/gl/0.1.0.tar.gz",
    \\            .hash = "1220placeholder",
    \\        },
    \\        .@"zpm-window" = .{
    \\            .url = "https://registry.zpm.dev/pkg/@zpm/window/0.1.0.tar.gz",
    \\            .hash = "1220placeholder",
    \\        },
    \\        .@"zpm-color" = .{
    \\            .url = "https://registry.zpm.dev/pkg/@zpm/color/0.1.0.tar.gz",
    \\            .hash = "1220placeholder",
    \\        },
    \\        .@"zpm-primitives" = .{
    \\            .url = "https://registry.zpm.dev/pkg/@zpm/primitives/0.1.0.tar.gz",
    \\            .hash = "1220placeholder",
    \\        },
    \\        .@"zpm-text" = .{
    \\            .url = "https://registry.zpm.dev/pkg/@zpm/text/0.1.0.tar.gz",
    \\            .hash = "1220placeholder",
    \\        },
    \\        .@"zpm-timer" = .{
    \\            .url = "https://registry.zpm.dev/pkg/@zpm/timer/0.1.0.tar.gz",
    \\            .hash = "1220placeholder",
    \\        },
    \\        .@"zpm-input" = .{
    \\            .url = "https://registry.zpm.dev/pkg/@zpm/input/0.1.0.tar.gz",
    \\            .hash = "1220placeholder",
    \\        },
    \\        .@"zpm-http" = .{
    \\            .url = "https://registry.zpm.dev/pkg/@zpm/http/0.1.0.tar.gz",
    \\            .hash = "1220placeholder",
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

const build_zig_zon_package =
    \\.{
    \\    .name = .@"{{project_name}}",
    \\    .version = "0.1.0",
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

const build_zig_zon_cli_app =
    \\.{
    \\    .name = .@"{{project_name}}",
    \\    .version = "0.1.0",
    \\    .minimum_zig_version = "0.16.0",
    \\    .dependencies = .{
    \\        .@"zpm-core" = .{
    \\            .url = "https://registry.zpm.dev/pkg/@zpm/core/0.1.0.tar.gz",
    \\            .hash = "1220placeholder",
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

const build_zig_zon_web_server =
    \\.{
    \\    .name = .@"{{project_name}}",
    \\    .version = "0.1.0",
    \\    .minimum_zig_version = "0.16.0",
    \\    .dependencies = .{
    \\        .@"zpm-core" = .{
    \\            .url = "https://registry.zpm.dev/pkg/@zpm/core/0.1.0.tar.gz",
    \\            .hash = "1220placeholder",
    \\        },
    \\        .@"zpm-http" = .{
    \\            .url = "https://registry.zpm.dev/pkg/@zpm/http/0.1.0.tar.gz",
    \\            .hash = "1220placeholder",
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

const build_zig_zon_gui_app =
    \\.{
    \\    .name = .@"{{project_name}}",
    \\    .version = "0.1.0",
    \\    .minimum_zig_version = "0.16.0",
    \\    .dependencies = .{
    \\        .@"zpm-core" = .{
    \\            .url = "https://registry.zpm.dev/pkg/@zpm/core/0.1.0.tar.gz",
    \\            .hash = "1220placeholder",
    \\        },
    \\        .@"zpm-win32" = .{
    \\            .url = "https://registry.zpm.dev/pkg/@zpm/win32/0.1.0.tar.gz",
    \\            .hash = "1220placeholder",
    \\        },
    \\        .@"zpm-gl" = .{
    \\            .url = "https://registry.zpm.dev/pkg/@zpm/gl/0.1.0.tar.gz",
    \\            .hash = "1220placeholder",
    \\        },
    \\        .@"zpm-window" = .{
    \\            .url = "https://registry.zpm.dev/pkg/@zpm/window/0.1.0.tar.gz",
    \\            .hash = "1220placeholder",
    \\        },
    \\        .@"zpm-color" = .{
    \\            .url = "https://registry.zpm.dev/pkg/@zpm/color/0.1.0.tar.gz",
    \\            .hash = "1220placeholder",
    \\        },
    \\        .@"zpm-primitives" = .{
    \\            .url = "https://registry.zpm.dev/pkg/@zpm/primitives/0.1.0.tar.gz",
    \\            .hash = "1220placeholder",
    \\        },
    \\        .@"zpm-timer" = .{
    \\            .url = "https://registry.zpm.dev/pkg/@zpm/timer/0.1.0.tar.gz",
    \\            .hash = "1220placeholder",
    \\        },
    \\        .@"zpm-input" = .{
    \\            .url = "https://registry.zpm.dev/pkg/@zpm/input/0.1.0.tar.gz",
    \\            .hash = "1220placeholder",
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

const build_zig_zon_library =
    \\.{
    \\    .name = .@"{{project_name}}",
    \\    .version = "0.1.0",
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

// ── build.zig Generator ──

fn generateBuildZig(project_name: []const u8, tmpl: Template, buf: *[8192]u8) ?[]const u8 {
    const template_str = switch (tmpl) {
        .empty => build_zig_empty,
        .window => build_zig_window,
        .gl_app => build_zig_gl_app,
        .trading => build_zig_trading,
        .package => build_zig_package,
        .cli_app => build_zig_cli_app,
        .web_server => build_zig_web_server,
        .gui_app => build_zig_gui_app,
        .library => build_zig_library,
    };
    return replacePlaceholder(template_str, project_name, buf);
}

const build_zig_empty =
    \\const std = @import("std");
    \\
    \\pub fn build(b: *std.Build) void {
    \\    const target = b.standardTargetOptions(.{});
    \\    const optimize = b.standardOptimizeOption(.{});
    \\
    \\    const exe = b.addExecutable(.{
    \\        .name = "{{project_name}}",
    \\        .root_module = b.createModule(.{
    \\            .root_source_file = b.path("src/main.zig"),
    \\            .target = target,
    \\            .optimize = optimize,
    \\        }),
    \\    });
    \\
    \\    b.installArtifact(exe);
    \\
    \\    const run_cmd = b.addRunArtifact(exe);
    \\    run_cmd.step.dependOn(b.getInstallStep());
    \\    const run_step = b.step("run", "Run the application");
    \\    run_step.dependOn(&run_cmd.step);
    \\}
    \\
;

const build_zig_window =
    \\const std = @import("std");
    \\
    \\pub fn build(b: *std.Build) void {
    \\    const target = b.standardTargetOptions(.{});
    \\    const optimize = b.standardOptimizeOption(.{});
    \\
    \\    // Zpm dependencies (auto-generated by zpm init)
    \\    const core_dep = b.dependency("zpm-core", .{ .target = target, .optimize = optimize });
    \\    const win32_dep = b.dependency("zpm-win32", .{ .target = target, .optimize = optimize });
    \\    const gl_dep = b.dependency("zpm-gl", .{ .target = target, .optimize = optimize });
    \\    const window_dep = b.dependency("zpm-window", .{ .target = target, .optimize = optimize });
    \\
    \\    const exe = b.addExecutable(.{
    \\        .name = "{{project_name}}",
    \\        .root_module = b.createModule(.{
    \\            .root_source_file = b.path("src/main.zig"),
    \\            .target = target,
    \\            .optimize = optimize,
    \\        }),
    \\    });
    \\
    \\    exe.root_module.addImport("core", core_dep.module("core"));
    \\    exe.root_module.addImport("win32", win32_dep.module("win32"));
    \\    exe.root_module.addImport("gl", gl_dep.module("gl"));
    \\    exe.root_module.addImport("window", window_dep.module("window"));
    \\
    \\    b.installArtifact(exe);
    \\
    \\    const run_cmd = b.addRunArtifact(exe);
    \\    run_cmd.step.dependOn(b.getInstallStep());
    \\    const run_step = b.step("run", "Run the application");
    \\    run_step.dependOn(&run_cmd.step);
    \\}
    \\
;

const build_zig_gl_app =
    \\const std = @import("std");
    \\
    \\pub fn build(b: *std.Build) void {
    \\    const target = b.standardTargetOptions(.{});
    \\    const optimize = b.standardOptimizeOption(.{});
    \\
    \\    // Zpm dependencies (auto-generated by zpm init)
    \\    const core_dep = b.dependency("zpm-core", .{ .target = target, .optimize = optimize });
    \\    const win32_dep = b.dependency("zpm-win32", .{ .target = target, .optimize = optimize });
    \\    const gl_dep = b.dependency("zpm-gl", .{ .target = target, .optimize = optimize });
    \\    const window_dep = b.dependency("zpm-window", .{ .target = target, .optimize = optimize });
    \\    const color_dep = b.dependency("zpm-color", .{ .target = target, .optimize = optimize });
    \\    const primitives_dep = b.dependency("zpm-primitives", .{ .target = target, .optimize = optimize });
    \\    const timer_dep = b.dependency("zpm-timer", .{ .target = target, .optimize = optimize });
    \\    const input_dep = b.dependency("zpm-input", .{ .target = target, .optimize = optimize });
    \\
    \\    const exe = b.addExecutable(.{
    \\        .name = "{{project_name}}",
    \\        .root_module = b.createModule(.{
    \\            .root_source_file = b.path("src/main.zig"),
    \\            .target = target,
    \\            .optimize = optimize,
    \\        }),
    \\    });
    \\
    \\    exe.root_module.addImport("core", core_dep.module("core"));
    \\    exe.root_module.addImport("win32", win32_dep.module("win32"));
    \\    exe.root_module.addImport("gl", gl_dep.module("gl"));
    \\    exe.root_module.addImport("window", window_dep.module("window"));
    \\    exe.root_module.addImport("color", color_dep.module("color"));
    \\    exe.root_module.addImport("primitives", primitives_dep.module("primitives"));
    \\    exe.root_module.addImport("timer", timer_dep.module("timer"));
    \\    exe.root_module.addImport("input", input_dep.module("input"));
    \\
    \\    b.installArtifact(exe);
    \\
    \\    const run_cmd = b.addRunArtifact(exe);
    \\    run_cmd.step.dependOn(b.getInstallStep());
    \\    const run_step = b.step("run", "Run the application");
    \\    run_step.dependOn(&run_cmd.step);
    \\}
    \\
;

const build_zig_trading =
    \\const std = @import("std");
    \\
    \\pub fn build(b: *std.Build) void {
    \\    const target = b.standardTargetOptions(.{});
    \\    const optimize = b.standardOptimizeOption(.{});
    \\
    \\    // Zpm dependencies (auto-generated by zpm init)
    \\    const core_dep = b.dependency("zpm-core", .{ .target = target, .optimize = optimize });
    \\    const win32_dep = b.dependency("zpm-win32", .{ .target = target, .optimize = optimize });
    \\    const gl_dep = b.dependency("zpm-gl", .{ .target = target, .optimize = optimize });
    \\    const window_dep = b.dependency("zpm-window", .{ .target = target, .optimize = optimize });
    \\    const color_dep = b.dependency("zpm-color", .{ .target = target, .optimize = optimize });
    \\    const primitives_dep = b.dependency("zpm-primitives", .{ .target = target, .optimize = optimize });
    \\    const text_dep = b.dependency("zpm-text", .{ .target = target, .optimize = optimize });
    \\    const timer_dep = b.dependency("zpm-timer", .{ .target = target, .optimize = optimize });
    \\    const input_dep = b.dependency("zpm-input", .{ .target = target, .optimize = optimize });
    \\    const http_dep = b.dependency("zpm-http", .{ .target = target, .optimize = optimize });
    \\
    \\    const exe = b.addExecutable(.{
    \\        .name = "{{project_name}}",
    \\        .root_module = b.createModule(.{
    \\            .root_source_file = b.path("src/main.zig"),
    \\            .target = target,
    \\            .optimize = optimize,
    \\        }),
    \\    });
    \\
    \\    exe.root_module.addImport("core", core_dep.module("core"));
    \\    exe.root_module.addImport("win32", win32_dep.module("win32"));
    \\    exe.root_module.addImport("gl", gl_dep.module("gl"));
    \\    exe.root_module.addImport("window", window_dep.module("window"));
    \\    exe.root_module.addImport("color", color_dep.module("color"));
    \\    exe.root_module.addImport("primitives", primitives_dep.module("primitives"));
    \\    exe.root_module.addImport("text", text_dep.module("text"));
    \\    exe.root_module.addImport("timer", timer_dep.module("timer"));
    \\    exe.root_module.addImport("input", input_dep.module("input"));
    \\    exe.root_module.addImport("http", http_dep.module("http"));
    \\
    \\    b.installArtifact(exe);
    \\
    \\    const run_cmd = b.addRunArtifact(exe);
    \\    run_cmd.step.dependOn(b.getInstallStep());
    \\    const run_step = b.step("run", "Run the application");
    \\    run_step.dependOn(&run_cmd.step);
    \\}
    \\
;

const build_zig_package =
    \\const std = @import("std");
    \\
    \\pub fn build(b: *std.Build) void {
    \\    const target = b.standardTargetOptions(.{});
    \\    const optimize = b.standardOptimizeOption(.{});
    \\
    \\    _ = b.addModule("{{project_name}}", .{
    \\        .root_source_file = b.path("src/root.zig"),
    \\        .target = target,
    \\        .optimize = optimize,
    \\    });
    \\
    \\    const tests = b.addTest(.{
    \\        .root_module = b.createModule(.{
    \\            .root_source_file = b.path("src/root.zig"),
    \\            .target = target,
    \\            .optimize = optimize,
    \\        }),
    \\    });
    \\
    \\    const test_step = b.step("test", "Run unit tests");
    \\    test_step.dependOn(&b.addRunArtifact(tests).step);
    \\}
    \\
;

const build_zig_cli_app =
    \\const std = @import("std");
    \\
    \\pub fn build(b: *std.Build) void {
    \\    const target = b.standardTargetOptions(.{});
    \\    const optimize = b.standardOptimizeOption(.{});
    \\
    \\    const core_dep = b.dependency("zpm-core", .{ .target = target, .optimize = optimize });
    \\
    \\    const exe = b.addExecutable(.{
    \\        .name = "{{project_name}}",
    \\        .root_module = b.createModule(.{
    \\            .root_source_file = b.path("src/main.zig"),
    \\            .target = target,
    \\            .optimize = optimize,
    \\        }),
    \\    });
    \\
    \\    exe.root_module.addImport("core", core_dep.module("core"));
    \\
    \\    b.installArtifact(exe);
    \\
    \\    const run_cmd = b.addRunArtifact(exe);
    \\    run_cmd.step.dependOn(b.getInstallStep());
    \\    if (b.args) |args| run_cmd.addArgs(args);
    \\    const run_step = b.step("run", "Run the application");
    \\    run_step.dependOn(&run_cmd.step);
    \\}
    \\
;

const build_zig_web_server =
    \\const std = @import("std");
    \\
    \\pub fn build(b: *std.Build) void {
    \\    const target = b.standardTargetOptions(.{});
    \\    const optimize = b.standardOptimizeOption(.{});
    \\
    \\    const core_dep = b.dependency("zpm-core", .{ .target = target, .optimize = optimize });
    \\    const http_dep = b.dependency("zpm-http", .{ .target = target, .optimize = optimize });
    \\
    \\    const exe = b.addExecutable(.{
    \\        .name = "{{project_name}}",
    \\        .root_module = b.createModule(.{
    \\            .root_source_file = b.path("src/main.zig"),
    \\            .target = target,
    \\            .optimize = optimize,
    \\        }),
    \\    });
    \\
    \\    exe.root_module.addImport("core", core_dep.module("core"));
    \\    exe.root_module.addImport("http", http_dep.module("http"));
    \\
    \\    b.installArtifact(exe);
    \\
    \\    const run_cmd = b.addRunArtifact(exe);
    \\    run_cmd.step.dependOn(b.getInstallStep());
    \\    const run_step = b.step("run", "Run the server");
    \\    run_step.dependOn(&run_cmd.step);
    \\}
    \\
;

const build_zig_gui_app =
    \\const std = @import("std");
    \\
    \\pub fn build(b: *std.Build) void {
    \\    const target = b.standardTargetOptions(.{});
    \\    const optimize = b.standardOptimizeOption(.{});
    \\
    \\    const core_dep = b.dependency("zpm-core", .{ .target = target, .optimize = optimize });
    \\    const win32_dep = b.dependency("zpm-win32", .{ .target = target, .optimize = optimize });
    \\    const gl_dep = b.dependency("zpm-gl", .{ .target = target, .optimize = optimize });
    \\    const window_dep = b.dependency("zpm-window", .{ .target = target, .optimize = optimize });
    \\    const color_dep = b.dependency("zpm-color", .{ .target = target, .optimize = optimize });
    \\    const primitives_dep = b.dependency("zpm-primitives", .{ .target = target, .optimize = optimize });
    \\    const timer_dep = b.dependency("zpm-timer", .{ .target = target, .optimize = optimize });
    \\    const input_dep = b.dependency("zpm-input", .{ .target = target, .optimize = optimize });
    \\
    \\    const exe = b.addExecutable(.{
    \\        .name = "{{project_name}}",
    \\        .root_module = b.createModule(.{
    \\            .root_source_file = b.path("src/main.zig"),
    \\            .target = target,
    \\            .optimize = optimize,
    \\        }),
    \\    });
    \\
    \\    exe.root_module.addImport("core", core_dep.module("core"));
    \\    exe.root_module.addImport("win32", win32_dep.module("win32"));
    \\    exe.root_module.addImport("gl", gl_dep.module("gl"));
    \\    exe.root_module.addImport("window", window_dep.module("window"));
    \\    exe.root_module.addImport("color", color_dep.module("color"));
    \\    exe.root_module.addImport("primitives", primitives_dep.module("primitives"));
    \\    exe.root_module.addImport("timer", timer_dep.module("timer"));
    \\    exe.root_module.addImport("input", input_dep.module("input"));
    \\
    \\    b.installArtifact(exe);
    \\
    \\    const run_cmd = b.addRunArtifact(exe);
    \\    run_cmd.step.dependOn(b.getInstallStep());
    \\    const run_step = b.step("run", "Run the application");
    \\    run_step.dependOn(&run_cmd.step);
    \\}
    \\
;

const build_zig_library =
    \\const std = @import("std");
    \\
    \\pub fn build(b: *std.Build) void {
    \\    const target = b.standardTargetOptions(.{});
    \\    const optimize = b.standardOptimizeOption(.{});
    \\
    \\    _ = b.addModule("{{project_name}}", .{
    \\        .root_source_file = b.path("src/root.zig"),
    \\        .target = target,
    \\        .optimize = optimize,
    \\    });
    \\
    \\    const tests = b.addTest(.{
    \\        .root_module = b.createModule(.{
    \\            .root_source_file = b.path("src/root.zig"),
    \\            .target = target,
    \\            .optimize = optimize,
    \\        }),
    \\    });
    \\
    \\    const test_step = b.step("test", "Run unit tests");
    \\    test_step.dependOn(&b.addRunArtifact(tests).step);
    \\}
    \\
;

// ── src/main.zig (or src/root.zig) Generator ──

fn generateMainZig(project_name: []const u8, tmpl: Template, buf: *[4096]u8) ?[]const u8 {
    const template_str = switch (tmpl) {
        .empty => main_zig_empty,
        .window => main_zig_window,
        .gl_app => main_zig_gl_app,
        .trading => main_zig_trading,
        .package => main_zig_package,
        .cli_app => main_zig_cli_app,
        .web_server => main_zig_web_server,
        .gui_app => main_zig_gui_app,
        .library => main_zig_library,
    };
    return replacePlaceholder(template_str, project_name, buf);
}

const main_zig_empty =
    \\const std = @import("std");
    \\
    \\pub fn main() void {
    \\    std.debug.print("Hello from {{project_name}}!\n", .{});
    \\}
    \\
;

const main_zig_window =
    \\const gl = @import("gl");
    \\const win = @import("window");
    \\
    \\pub fn main() void {
    \\    var window = win.Window.init("{{project_name}}", 1280, 720);
    \\    defer window.deinit();
    \\
    \\    while (window.isOpen()) {
    \\        gl.glClearColor(0.08, 0.08, 0.12, 1.0);
    \\        gl.glClear(gl.GL_COLOR_BUFFER_BIT);
    \\        window.swap();
    \\    }
    \\}
    \\
;

const main_zig_gl_app =
    \\const gl = @import("gl");
    \\const win = @import("window");
    \\const prim = @import("primitives");
    \\const color = @import("color");
    \\const timer = @import("timer");
    \\const input = @import("input");
    \\
    \\pub fn main() void {
    \\    var t = timer.Timer.init();
    \\    var window = win.Window.init("{{project_name}}", 1280, 720);
    \\    defer window.deinit();
    \\
    \\    while (window.isOpen()) {
    \\        const dt = t.tick();
    \\        _ = dt;
    \\
    \\        input.poll(&window);
    \\        if (input.isKeyPressed(.escape)) window.close();
    \\
    \\        gl.glClearColor(0.08, 0.08, 0.12, 1.0);
    \\        gl.glClear(gl.GL_COLOR_BUFFER_BIT);
    \\
    \\        prim.rect(440, 260, 400, 200, color.accent);
    \\
    \\        window.swap();
    \\    }
    \\}
    \\
;

const main_zig_trading =
    \\const gl = @import("gl");
    \\const win = @import("window");
    \\const prim = @import("primitives");
    \\const color = @import("color");
    \\const text = @import("text");
    \\const timer = @import("timer");
    \\const input = @import("input");
    \\
    \\pub fn main() void {
    \\    var t = timer.Timer.init();
    \\    var window = win.Window.init("{{project_name}}", 1920, 1080);
    \\    defer window.deinit();
    \\
    \\    while (window.isOpen()) {
    \\        const dt = t.tick();
    \\        _ = dt;
    \\
    \\        input.poll(&window);
    \\        if (input.isKeyPressed(.escape)) window.close();
    \\
    \\        gl.glClearColor(0.06, 0.06, 0.10, 1.0);
    \\        gl.glClear(gl.GL_COLOR_BUFFER_BIT);
    \\
    \\        text.draw("{{project_name}}", 20, 20, color.white);
    \\
    \\        window.swap();
    \\    }
    \\}
    \\
;

const main_zig_package =
    \\/// {{project_name}} — a zpm-compatible package.
    \\pub fn init() void {}
    \\
    \\test "{{project_name}} basic test" {
    \\    const std = @import("std");
    \\    try std.testing.expect(true);
    \\}
    \\
;

const main_zig_cli_app =
    \\const std = @import("std");
    \\
    \\pub fn main() void {
    \\    // Cross-platform CLI application — {{project_name}}
    \\    const args = std.process.argsWithAllocator(std.heap.page_allocator) catch return;
    \\    defer args.deinit();
    \\
    \\    var count: usize = 0;
    \\    while (args.next()) |_| count += 1;
    \\
    \\    var buf: [256]u8 = undefined;
    \\    const msg = std.fmt.bufPrint(&buf, "{{project_name}}: {d} argument(s)\n", .{count}) catch return;
    \\    std.debug.print("{s}", .{msg});
    \\}
    \\
;

const main_zig_web_server =
    \\const std = @import("std");
    \\
    \\pub fn main() void {
    \\    // Zig HTTP server — {{project_name}}
    \\    std.debug.print("{{project_name}} server starting on :8080\n", .{});
    \\    // TODO: Initialize HTTP listener and route handlers
    \\    std.debug.print("{{project_name}} server ready\n", .{});
    \\}
    \\
;

const main_zig_gui_app =
    \\const gl = @import("gl");
    \\const win = @import("window");
    \\const prim = @import("primitives");
    \\const color = @import("color");
    \\const timer = @import("timer");
    \\const input = @import("input");
    \\
    \\pub fn main() void {
    \\    // Platform-abstracted GUI application — {{project_name}}
    \\    var t = timer.Timer.init();
    \\    var window = win.Window.init("{{project_name}}", 1280, 720);
    \\    defer window.deinit();
    \\
    \\    while (window.isOpen()) {
    \\        const dt = t.tick();
    \\        _ = dt;
    \\
    \\        input.poll(&window);
    \\        if (input.isKeyPressed(.escape)) window.close();
    \\
    \\        gl.glClearColor(0.08, 0.08, 0.12, 1.0);
    \\        gl.glClear(gl.GL_COLOR_BUFFER_BIT);
    \\
    \\        prim.rect(340, 210, 600, 300, color.accent);
    \\
    \\        window.swap();
    \\    }
    \\}
    \\
;

const main_zig_library =
    \\/// {{project_name}} — a reusable Zig module.
    \\
    \\pub fn init() void {}
    \\
    \\test "{{project_name}} basic test" {
    \\    const std = @import("std");
    \\    try std.testing.expect(true);
    \\}
    \\
;

// ── .gitignore Content ──

const gitignore_content =
    \\.zig-cache/
    \\zig-out/
    \\config.json
    \\
;

// ── README.md Generator ──

fn generateReadme(project_name: []const u8, tmpl: Template, buf: *[2048]u8) ?[]const u8 {
    const desc = switch (tmpl) {
        .empty => "A minimal Zig project.",
        .window => "A borderless GL window application.",
        .gl_app => "A GL application with render loop and basic drawing.",
        .trading => "A trading chart application skeleton.",
        .package => "A publishable zpm-compatible package.",
        .cli_app => "A cross-platform command-line application with argument parsing.",
        .web_server => "A Zig HTTP server project.",
        .gui_app => "A platform-abstracted GUI application with window and GL rendering.",
        .library => "A reusable Zig module with test infrastructure.",
    };
    const template_str = readme_template;
    // Two-pass: first replace {{project_name}}, then {{description}}
    var tmp_buf: [2048]u8 = undefined;
    const pass1 = replacePlaceholder(template_str, project_name, &tmp_buf) orelse return null;
    return replaceDescPlaceholder(pass1, desc, buf);
}

fn replaceDescPlaceholder(template: []const u8, desc: []const u8, buf: []u8) ?[]const u8 {
    const placeholder = "{{description}}";
    var out_pos: usize = 0;
    var in_pos: usize = 0;

    while (in_pos < template.len) {
        if (in_pos + placeholder.len <= template.len and
            strEql(template[in_pos .. in_pos + placeholder.len], placeholder))
        {
            if (out_pos + desc.len > buf.len) return null;
            @memcpy(buf[out_pos .. out_pos + desc.len], desc);
            out_pos += desc.len;
            in_pos += placeholder.len;
        } else {
            if (out_pos >= buf.len) return null;
            buf[out_pos] = template[in_pos];
            out_pos += 1;
            in_pos += 1;
        }
    }
    return buf[0..out_pos];
}

const readme_template =
    \\# {{project_name}}
    \\
    \\{{description}}
    \\
    \\## Build
    \\
    \\```
    \\zig build
    \\```
    \\
    \\## Run
    \\
    \\```
    \\zpm run
    \\```
    \\
;

// ── zpm.pkg.zon Generator (package template only) ──

fn generateZpmPkgZon(project_name: []const u8, layer: u2, buf: *[2048]u8) ?[]const u8 {
    const layer_char: u8 = '0' + @as(u8, layer);
    const template_str = zpm_pkg_zon_template;
    // Replace {{project_name}} first
    var tmp_buf: [2048]u8 = undefined;
    const pass1 = replacePlaceholder(template_str, project_name, &tmp_buf) orelse return null;
    // Replace {{layer}} with the digit
    return replaceLayerPlaceholder(pass1, layer_char, buf);
}

fn replaceLayerPlaceholder(template: []const u8, layer_char: u8, buf: []u8) ?[]const u8 {
    const placeholder = "{{layer}}";
    var out_pos: usize = 0;
    var in_pos: usize = 0;

    while (in_pos < template.len) {
        if (in_pos + placeholder.len <= template.len and
            strEql(template[in_pos .. in_pos + placeholder.len], placeholder))
        {
            if (out_pos >= buf.len) return null;
            buf[out_pos] = layer_char;
            out_pos += 1;
            in_pos += placeholder.len;
        } else {
            if (out_pos >= buf.len) return null;
            buf[out_pos] = template[in_pos];
            out_pos += 1;
            in_pos += 1;
        }
    }
    return buf[0..out_pos];
}

const zpm_pkg_zon_template =
    \\.{
    \\    .protocol_version = 1,
    \\    .scope = "zpm",
    \\    .name = "{{project_name}}",
    \\    .version = "0.1.0",
    \\    .layer = {{layer}},
    \\    .platform = .any,
    \\    .system_libraries = .{},
    \\    .zpm_dependencies = .{},
    \\    .exports = .{ "{{project_name}}" },
    \\    .constraints = .{
    \\        .no_allocator = true,
    \\        .no_std_io = true,
    \\    },
    \\}
    \\
;

// ── Tests ──

const testing = std.testing;

// ── Mock Vtable Infrastructure ──

var mock_dirs_created: [16][512]u8 = undefined;
var mock_dirs_created_lens: [16]usize = undefined;
var mock_dir_count: usize = 0;

var mock_files_written: [16]MockWrittenFile = undefined;
var mock_file_write_count: usize = 0;

var mock_existing_dirs: [8][512]u8 = undefined;
var mock_existing_dirs_lens: [8]usize = undefined;
var mock_existing_dir_count: usize = 0;
var mock_existing_dirs_empty: [8]bool = undefined;

var mock_removed_dirs: [8][512]u8 = undefined;
var mock_removed_dirs_lens: [8]usize = undefined;
var mock_removed_dir_count: usize = 0;

var mock_init_print_buf: [2048]u8 = undefined;
var mock_init_print_len: usize = 0;

var mock_create_dir_fail: bool = false;
var mock_write_file_fail: bool = false;
var mock_write_file_fail_on: ?[]const u8 = null;
var mock_remove_dir_fail: bool = false;

const MockWrittenFile = struct {
    path: [512]u8,
    path_len: usize,
    content: [8192]u8,
    content_len: usize,
};

fn resetInitMocks() void {
    mock_dir_count = 0;
    mock_file_write_count = 0;
    mock_existing_dir_count = 0;
    mock_removed_dir_count = 0;
    mock_init_print_len = 0;
    mock_create_dir_fail = false;
    mock_write_file_fail = false;
    mock_write_file_fail_on = null;
    mock_remove_dir_fail = false;
}

fn addExistingDir(path: []const u8, empty: bool) void {
    if (mock_existing_dir_count < mock_existing_dirs.len) {
        const i = mock_existing_dir_count;
        const copy_len = @min(path.len, mock_existing_dirs[i].len);
        @memcpy(mock_existing_dirs[i][0..copy_len], path[0..copy_len]);
        mock_existing_dirs_lens[i] = copy_len;
        mock_existing_dirs_empty[i] = empty;
        mock_existing_dir_count += 1;
    }
}

fn mockCreateDir(path: []const u8) bool {
    if (mock_create_dir_fail) return false;
    if (mock_dir_count < mock_dirs_created.len) {
        const i = mock_dir_count;
        const copy_len = @min(path.len, mock_dirs_created[i].len);
        @memcpy(mock_dirs_created[i][0..copy_len], path[0..copy_len]);
        mock_dirs_created_lens[i] = copy_len;
        mock_dir_count += 1;
    }
    return true;
}

fn mockInitWriteFile(path: []const u8, content: []const u8) bool {
    if (mock_write_file_fail) return false;
    if (mock_write_file_fail_on) |fail_path| {
        if (containsSubstr(path, fail_path)) return false;
    }
    if (mock_file_write_count < mock_files_written.len) {
        const i = mock_file_write_count;
        const plen = @min(path.len, mock_files_written[i].path.len);
        @memcpy(mock_files_written[i].path[0..plen], path[0..plen]);
        mock_files_written[i].path_len = plen;
        const clen = @min(content.len, mock_files_written[i].content.len);
        @memcpy(mock_files_written[i].content[0..clen], content[0..clen]);
        mock_files_written[i].content_len = clen;
        mock_file_write_count += 1;
    }
    return true;
}

fn mockDirExists(path: []const u8) bool {
    for (0..mock_existing_dir_count) |i| {
        const existing = mock_existing_dirs[i][0..mock_existing_dirs_lens[i]];
        if (strEql(path, existing)) return true;
    }
    return false;
}

fn mockDirIsEmpty(path: []const u8) bool {
    for (0..mock_existing_dir_count) |i| {
        const existing = mock_existing_dirs[i][0..mock_existing_dirs_lens[i]];
        if (strEql(path, existing)) return mock_existing_dirs_empty[i];
    }
    return true;
}

fn mockRemoveDir(path: []const u8) bool {
    if (mock_remove_dir_fail) return false;
    if (mock_removed_dir_count < mock_removed_dirs.len) {
        const i = mock_removed_dir_count;
        const copy_len = @min(path.len, mock_removed_dirs[i].len);
        @memcpy(mock_removed_dirs[i][0..copy_len], path[0..copy_len]);
        mock_removed_dirs_lens[i] = copy_len;
        mock_removed_dir_count += 1;
    }
    return true;
}

fn mockInitPrint(msg: []const u8) void {
    const copy_len = @min(msg.len, mock_init_print_buf.len - mock_init_print_len);
    @memcpy(mock_init_print_buf[mock_init_print_len .. mock_init_print_len + copy_len], msg[0..copy_len]);
    mock_init_print_len += copy_len;
}

fn getInitPrintOutput() []const u8 {
    return mock_init_print_buf[0..mock_init_print_len];
}

fn containsSubstr(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    if (needle.len == 0) return true;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (strEql(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

fn getWrittenFilePath(index: usize) []const u8 {
    return mock_files_written[index].path[0..mock_files_written[index].path_len];
}

fn getWrittenFileContent(index: usize) []const u8 {
    return mock_files_written[index].content[0..mock_files_written[index].content_len];
}

fn findWrittenFile(suffix: []const u8) ?usize {
    for (0..mock_file_write_count) |i| {
        if (containsSubstr(getWrittenFilePath(i), suffix)) return i;
    }
    return null;
}

const mock_init_vtable = InitVtable{
    .create_dir = &mockCreateDir,
    .write_file = &mockInitWriteFile,
    .dir_exists = &mockDirExists,
    .dir_is_empty = &mockDirIsEmpty,
    .remove_dir = &mockRemoveDir,
    .print = &mockInitPrint,
};

// ── Test: Scaffold creates all expected files ──

test "scaffold: empty template creates all expected files" {
    resetInitMocks();
    const config = InitConfig{
        .project_name = "my-app",
        .template = .empty,
    };
    const result = scaffold(&mock_init_vtable, &config);
    try testing.expectEqual(InitResult.success, result);

    // Should have created project dir + src dir = 2 dirs
    try testing.expectEqual(@as(usize, 2), mock_dir_count);

    // Should have written: build.zig.zon, build.zig, src/main.zig, .gitignore, README.md = 5 files
    try testing.expectEqual(@as(usize, 5), mock_file_write_count);

    // Verify each expected file exists
    try testing.expect(findWrittenFile("build.zig.zon") != null);
    try testing.expect(findWrittenFile("build.zig") != null);
    try testing.expect(findWrittenFile("src/main.zig") != null);
    try testing.expect(findWrittenFile(".gitignore") != null);
    try testing.expect(findWrittenFile("README.md") != null);
}

test "scaffold: package template creates zpm.pkg.zon and src/root.zig" {
    resetInitMocks();
    const config = InitConfig{
        .project_name = "my-pkg",
        .template = .package,
        .package_layer = 1,
    };
    const result = scaffold(&mock_init_vtable, &config);
    try testing.expectEqual(InitResult.success, result);

    // 5 standard files + zpm.pkg.zon = 6
    try testing.expectEqual(@as(usize, 6), mock_file_write_count);
    try testing.expect(findWrittenFile("zpm.pkg.zon") != null);
    try testing.expect(findWrittenFile("src/root.zig") != null);
    // Should NOT have src/main.zig
    try testing.expect(findWrittenFile("src/main.zig") == null);
}

// ── Test: {{project_name}} replacement works ──

test "scaffold: project_name placeholder replaced in all files" {
    resetInitMocks();
    const config = InitConfig{
        .project_name = "cool-project",
        .template = .empty,
    };
    const result = scaffold(&mock_init_vtable, &config);
    try testing.expectEqual(InitResult.success, result);

    // Check build.zig.zon contains project name, not placeholder
    const zon_idx = findWrittenFile("build.zig.zon").?;
    const zon_content = getWrittenFileContent(zon_idx);
    try testing.expect(containsSubstr(zon_content, "cool-project"));
    try testing.expect(!containsSubstr(zon_content, "{{project_name}}"));

    // Check build.zig
    const build_idx = findWrittenFile("build.zig").?;
    const build_content = getWrittenFileContent(build_idx);
    try testing.expect(containsSubstr(build_content, "cool-project"));
    try testing.expect(!containsSubstr(build_content, "{{project_name}}"));

    // Check src/main.zig
    const main_idx = findWrittenFile("src/main.zig").?;
    const main_content = getWrittenFileContent(main_idx);
    try testing.expect(containsSubstr(main_content, "cool-project"));
    try testing.expect(!containsSubstr(main_content, "{{project_name}}"));

    // Check README.md
    const readme_idx = findWrittenFile("README.md").?;
    const readme_content = getWrittenFileContent(readme_idx);
    try testing.expect(containsSubstr(readme_content, "cool-project"));
    try testing.expect(!containsSubstr(readme_content, "{{project_name}}"));
}

// ── Test: Dir exists rejection ──

test "scaffold: rejects when dir exists and not empty" {
    resetInitMocks();
    addExistingDir("my-app", false); // exists, not empty

    const config = InitConfig{
        .project_name = "my-app",
        .template = .empty,
    };
    const result = scaffold(&mock_init_vtable, &config);
    try testing.expectEqual(InitResult.dir_exists_not_empty, result);
    try testing.expect(mock_file_write_count == 0);
    try testing.expect(containsSubstr(getInitPrintOutput(), "--force"));
}

test "scaffold: allows when dir exists but is empty" {
    resetInitMocks();
    addExistingDir("my-app", true); // exists, empty

    const config = InitConfig{
        .project_name = "my-app",
        .template = .empty,
    };
    const result = scaffold(&mock_init_vtable, &config);
    try testing.expectEqual(InitResult.success, result);
}

// ── Test: Force flag overrides dir check ──

test "scaffold: force flag overrides non-empty dir check" {
    resetInitMocks();
    addExistingDir("my-app", false); // exists, not empty

    const config = InitConfig{
        .project_name = "my-app",
        .template = .empty,
        .force = true,
    };
    const result = scaffold(&mock_init_vtable, &config);
    try testing.expectEqual(InitResult.success, result);

    // Should have removed the old dir
    try testing.expectEqual(@as(usize, 1), mock_removed_dir_count);
}

// ── Test: Each template produces valid output ──

test "scaffold: window template produces correct deps" {
    resetInitMocks();
    const config = InitConfig{
        .project_name = "win-app",
        .template = .window,
    };
    const result = scaffold(&mock_init_vtable, &config);
    try testing.expectEqual(InitResult.success, result);

    const zon_idx = findWrittenFile("build.zig.zon").?;
    const zon_content = getWrittenFileContent(zon_idx);
    try testing.expect(containsSubstr(zon_content, "zpm-core"));
    try testing.expect(containsSubstr(zon_content, "zpm-window"));
    try testing.expect(containsSubstr(zon_content, "zpm-gl"));
    try testing.expect(containsSubstr(zon_content, "zpm-win32"));
}

test "scaffold: gl-app template produces correct deps" {
    resetInitMocks();
    const config = InitConfig{
        .project_name = "gl-test",
        .template = .gl_app,
    };
    const result = scaffold(&mock_init_vtable, &config);
    try testing.expectEqual(InitResult.success, result);

    const zon_idx = findWrittenFile("build.zig.zon").?;
    const zon_content = getWrittenFileContent(zon_idx);
    try testing.expect(containsSubstr(zon_content, "zpm-color"));
    try testing.expect(containsSubstr(zon_content, "zpm-primitives"));
    try testing.expect(containsSubstr(zon_content, "zpm-timer"));
    try testing.expect(containsSubstr(zon_content, "zpm-input"));
}

test "scaffold: trading template produces correct deps" {
    resetInitMocks();
    const config = InitConfig{
        .project_name = "trade-app",
        .template = .trading,
    };
    const result = scaffold(&mock_init_vtable, &config);
    try testing.expectEqual(InitResult.success, result);

    const zon_idx = findWrittenFile("build.zig.zon").?;
    const zon_content = getWrittenFileContent(zon_idx);
    try testing.expect(containsSubstr(zon_content, "zpm-text"));
    try testing.expect(containsSubstr(zon_content, "zpm-http"));
}

test "scaffold: package template generates zpm.pkg.zon with correct layer" {
    resetInitMocks();
    const config = InitConfig{
        .project_name = "my-lib",
        .template = .package,
        .package_layer = 2,
    };
    const result = scaffold(&mock_init_vtable, &config);
    try testing.expectEqual(InitResult.success, result);

    const pkg_idx = findWrittenFile("zpm.pkg.zon").?;
    const pkg_content = getWrittenFileContent(pkg_idx);
    try testing.expect(containsSubstr(pkg_content, ".layer = 2"));
    try testing.expect(containsSubstr(pkg_content, "my-lib"));
}

// ── Test: Failure cleanup removes partial dir ──

test "scaffold: cleanup on write failure" {
    resetInitMocks();
    mock_write_file_fail_on = "README.md"; // fail on README

    const config = InitConfig{
        .project_name = "fail-app",
        .template = .empty,
    };
    const result = scaffold(&mock_init_vtable, &config);
    try testing.expectEqual(InitResult.failed, result);

    // Should have attempted cleanup
    try testing.expectEqual(@as(usize, 1), mock_removed_dir_count);
    try testing.expect(containsSubstr(getInitPrintOutput(), "cleaned up"));
}

test "scaffold: cleanup on create_dir failure" {
    resetInitMocks();
    mock_create_dir_fail = true;

    const config = InitConfig{
        .project_name = "fail-app",
        .template = .empty,
    };
    const result = scaffold(&mock_init_vtable, &config);
    try testing.expectEqual(InitResult.failed, result);
}

// ── Test: Template.fromString ──

test "Template.fromString: valid templates" {
    try testing.expectEqual(Template.empty, Template.fromString("empty").?);
    try testing.expectEqual(Template.window, Template.fromString("window").?);
    try testing.expectEqual(Template.gl_app, Template.fromString("gl-app").?);
    try testing.expectEqual(Template.trading, Template.fromString("trading").?);
    try testing.expectEqual(Template.package, Template.fromString("package").?);
    try testing.expectEqual(Template.cli_app, Template.fromString("cli-app").?);
    try testing.expectEqual(Template.web_server, Template.fromString("web-server").?);
    try testing.expectEqual(Template.gui_app, Template.fromString("gui-app").?);
    try testing.expectEqual(Template.library, Template.fromString("library").?);
}

test "Template.fromString: unknown template returns null" {
    try testing.expect(Template.fromString("nonexistent") == null);
    try testing.expect(Template.fromString("") == null);
}

// ── Test: replacePlaceholder ──

test "replacePlaceholder: basic substitution" {
    var buf: [256]u8 = undefined;
    const result = replacePlaceholder("hello {{project_name}}!", "world", &buf).?;
    try testing.expectEqualStrings("hello world!", result);
}

test "replacePlaceholder: multiple occurrences" {
    var buf: [256]u8 = undefined;
    const result = replacePlaceholder("{{project_name}}-{{project_name}}", "x", &buf).?;
    try testing.expectEqualStrings("x-x", result);
}

test "replacePlaceholder: no placeholder" {
    var buf: [256]u8 = undefined;
    const result = replacePlaceholder("no placeholders here", "x", &buf).?;
    try testing.expectEqualStrings("no placeholders here", result);
}

// ── Property Tests ──

// **Property 16: Init Atomicity**
// Validates: Requirements 16.6, 16.8
// For any failure during scaffolding, the cleanup function shall be called
// (mock_removed_dir_count > 0) and the result shall be .failed.

test "property 16: init atomicity — failures at each step trigger cleanup" {
    // **Validates: Requirements 16.6, 16.8**
    const templates = [_]Template{ .empty, .window, .gl_app, .trading, .package, .cli_app, .web_server, .gui_app, .library };

    // Test failure on create_dir (project dir creation)
    for (templates) |tmpl| {
        resetInitMocks();
        mock_create_dir_fail = true;

        const config = InitConfig{
            .project_name = "test-proj",
            .template = tmpl,
        };
        const result = scaffold(&mock_init_vtable, &config);
        try testing.expectEqual(InitResult.failed, result);
    }

    // Test failure on each file write step by failing on specific file suffixes
    const fail_targets = [_][]const u8{
        "build.zig.zon",
        "build.zig",
        "src/main.zig",
        ".gitignore",
        "README.md",
    };

    for (fail_targets) |target| {
        for (templates) |tmpl| {
            // For package and library templates, src file is root.zig not main.zig
            if ((tmpl == .package or tmpl == .library) and containsSubstr(target, "src/main.zig")) continue;

            resetInitMocks();
            mock_write_file_fail_on = target;

            const config = InitConfig{
                .project_name = "test-proj",
                .template = tmpl,
                .package_layer = if (tmpl == .package) 0 else null,
            };
            const result = scaffold(&mock_init_vtable, &config);
            try testing.expectEqual(InitResult.failed, result);

            // Cleanup must have been called
            try testing.expect(mock_removed_dir_count > 0);
        }
    }

    // Also test package/library-specific: fail on src/root.zig
    {
        resetInitMocks();
        mock_write_file_fail_on = "src/root.zig";

        const config = InitConfig{
            .project_name = "test-proj",
            .template = .package,
            .package_layer = 0,
        };
        const result = scaffold(&mock_init_vtable, &config);
        try testing.expectEqual(InitResult.failed, result);
        try testing.expect(mock_removed_dir_count > 0);
    }

    // Also test library: fail on src/root.zig
    {
        resetInitMocks();
        mock_write_file_fail_on = "src/root.zig";

        const config = InitConfig{
            .project_name = "test-proj",
            .template = .library,
        };
        const result = scaffold(&mock_init_vtable, &config);
        try testing.expectEqual(InitResult.failed, result);
        try testing.expect(mock_removed_dir_count > 0);
    }

    // Also test package-specific: fail on zpm.pkg.zon
    {
        resetInitMocks();
        mock_write_file_fail_on = "zpm.pkg.zon";

        const config = InitConfig{
            .project_name = "test-proj",
            .template = .package,
            .package_layer = 0,
        };
        const result = scaffold(&mock_init_vtable, &config);
        try testing.expectEqual(InitResult.failed, result);
        try testing.expect(mock_removed_dir_count > 0);
    }
}

// **Property 17: Template Placeholder Substitution**
// Validates: Requirement 16.10
// For each template, scaffold with a random project name, verify zero remaining
// {{project_name}} placeholders in all written files.

test "property 17: template placeholder substitution — no remaining placeholders" {
    // **Validates: Requirements 16.10**
    const templates = [_]Template{ .empty, .window, .gl_app, .trading, .package, .cli_app, .web_server, .gui_app, .library };
    const project_names = [_][]const u8{
        "a",           "my-app",     "cool-project", "x1",
        "test-pkg",    "hello",      "zig-lib",      "render",
        "ab",          "my-tool",    "demo",         "widget",
        "core-lib",    "platform",   "gl-render",    "timer",
        "http-client", "crypto-lib", "input-mgr",    "color-pkg",
    };

    var iter: usize = 0;
    while (iter < 200) : (iter += 1) {
        const tmpl = templates[iter % templates.len];
        const name = project_names[iter % project_names.len];

        resetInitMocks();

        const config = InitConfig{
            .project_name = name,
            .template = tmpl,
            .package_layer = if (tmpl == .package) 0 else null,
        };
        const result = scaffold(&mock_init_vtable, &config);
        try testing.expectEqual(InitResult.success, result);

        // Check every written file for remaining placeholders
        for (0..mock_file_write_count) |i| {
            const content = getWrittenFileContent(i);
            try testing.expect(!containsSubstr(content, "{{project_name}}"));
        }
    }
}

// **Property 18: Init Determinism**
// Validates: Requirement 22.1
// Run scaffold twice with identical inputs, verify the written files are
// byte-identical.

test "property 18: init determinism — identical inputs produce identical outputs" {
    // **Validates: Requirements 22.1**
    const templates = [_]Template{ .empty, .window, .gl_app, .trading, .package, .cli_app, .web_server, .gui_app, .library };
    const project_names = [_][]const u8{
        "det-app",    "my-proj",    "test-lib",    "cool-thing",
        "zig-tool",   "render-pkg", "gl-demo",     "trade-bot",
        "core-util",  "platform-x", "timer-lib",   "http-svc",
        "crypto-pkg", "input-lib",  "color-util",  "window-app",
        "widget-lib", "icon-pkg",   "text-render", "math-core",
    };

    var iter: usize = 0;
    while (iter < 100) : (iter += 1) {
        const tmpl = templates[iter % templates.len];
        const name = project_names[iter % project_names.len];

        // First run
        resetInitMocks();
        const config = InitConfig{
            .project_name = name,
            .template = tmpl,
            .package_layer = if (tmpl == .package) @as(u2, @intCast(iter % 3)) else null,
        };
        const result1 = scaffold(&mock_init_vtable, &config);
        try testing.expectEqual(InitResult.success, result1);

        const count1 = mock_file_write_count;
        var contents1: [16]u64 = undefined;
        for (0..count1) |i| {
            const c = getWrittenFileContent(i);
            var h: u64 = 0xcbf29ce484222325;
            for (c) |b| {
                h ^= b;
                h *%= 0x100000001b3;
            }
            contents1[i] = h;
        }

        // Second run
        resetInitMocks();
        const result2 = scaffold(&mock_init_vtable, &config);
        try testing.expectEqual(InitResult.success, result2);

        const count2 = mock_file_write_count;
        try testing.expectEqual(count1, count2);

        for (0..count2) |i| {
            const c = getWrittenFileContent(i);
            var h: u64 = 0xcbf29ce484222325;
            for (c) |b| {
                h ^= b;
                h *%= 0x100000001b3;
            }
            try testing.expectEqual(contents1[i], h);
        }
    }
}

// **Property 23: Init File Completeness**
// Validates: Requirement 16.4
// For each template, verify scaffolded directory contains build.zig.zon,
// build.zig, src/ file (main.zig or root.zig), .gitignore, README.md.
// Package template also has zpm.pkg.zon.

test "property 23: init file completeness — all required files present" {
    // **Validates: Requirements 16.4**
    const templates = [_]Template{ .empty, .window, .gl_app, .trading, .package, .cli_app, .web_server, .gui_app, .library };

    for (templates) |tmpl| {
        resetInitMocks();

        const config = InitConfig{
            .project_name = "completeness-test",
            .template = tmpl,
            .package_layer = if (tmpl == .package) 0 else null,
        };
        const result = scaffold(&mock_init_vtable, &config);
        try testing.expectEqual(InitResult.success, result);

        // All templates must have these files
        try testing.expect(findWrittenFile("build.zig.zon") != null);
        try testing.expect(findWrittenFile("build.zig") != null);
        try testing.expect(findWrittenFile(".gitignore") != null);
        try testing.expect(findWrittenFile("README.md") != null);

        // Source file: package and library use root.zig, others use main.zig
        if (tmpl == .package or tmpl == .library) {
            try testing.expect(findWrittenFile("src/root.zig") != null);
        } else {
            try testing.expect(findWrittenFile("src/main.zig") != null);
        }

        // Package template must also have zpm.pkg.zon
        if (tmpl == .package) {
            try testing.expect(findWrittenFile("zpm.pkg.zon") != null);
        }
    }
}
