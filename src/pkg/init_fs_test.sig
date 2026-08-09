const std = @import("std");
const init = @import("init.sig");

const testing = std.testing;

var fs_root: std.Io.Dir = undefined;

fn createDir(path: []const u8) bool {
    fs_root.createDirPath(testing.io, path) catch return false;
    return true;
}

fn writeFile(path: []const u8, content: []const u8) bool {
    fs_root.writeFile(testing.io, .{ .sub_path = path, .data = content }) catch return false;
    return true;
}

fn dirExists(path: []const u8) bool {
    fs_root.access(testing.io, path, .{}) catch return false;
    return true;
}

fn dirIsEmpty(path: []const u8) bool {
    var dir = fs_root.openDir(testing.io, path, .{ .iterate = true }) catch return false;
    defer dir.close(testing.io);
    var it = dir.iterate();
    return (it.next(testing.io) catch return false) == null;
}

fn removeDir(path: []const u8) bool {
    fs_root.deleteTree(testing.io, path) catch return false;
    return true;
}

fn ignorePrint(_: []const u8) void {}

const fs_vtable = init.InitVtable{
    .create_dir = &createDir,
    .write_file = &writeFile,
    .dir_exists = &dirExists,
    .dir_is_empty = &dirIsEmpty,
    .remove_dir = &removeDir,
    .print = &ignorePrint,
};

fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

test "init fs: browser template materializes publishable Sig starter" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    fs_root = tmp.dir;

    const config = init.InitConfig{
        .project_name = "browser-generated",
        .template = .browser,
        .force = false,
    };

    try testing.expectEqual(init.InitResult.success, init.scaffold(&fs_vtable, &config));

    var file_buf: [8192]u8 = undefined;

    const build_sig = try fs_root.readFile(testing.io, "browser-generated/build.sig", &file_buf);
    try testing.expect(contains(build_sig, "@import(\"sig_build\")"));
    try testing.expect(contains(build_sig, "ctx.addModule(\"browser\", \"src/root.sig\")"));
    try testing.expect(!contains(build_sig, "std.Build"));

    const root_sig = try fs_root.readFile(testing.io, "browser-generated/src/root.sig", &file_buf);
    try testing.expect(contains(root_sig, "pub const Url"));
    try testing.expect(contains(root_sig, "pub fn loadStatic"));
    try testing.expect(contains(root_sig, "test \"browser starter parses URL and static title\""));

    const pkg_zon = try fs_root.readFile(testing.io, "browser-generated/zpm.pkg.zon", &file_buf);
    try testing.expect(contains(pkg_zon, ".scope = \"sb0\""));
    try testing.expect(contains(pkg_zon, ".exports = .{ \"browser\" }"));
    try testing.expect(contains(pkg_zon, ".no_allocator = true"));

    try testing.expectError(error.FileNotFound, fs_root.readFile(testing.io, "browser-generated/src/main.sig", &file_buf));
}
