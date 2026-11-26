//! Caller-provided file streams for SQL large-object transfers.
const Error = @import("types.sig").Error;

pub const Operation = enum { import_file, export_file };

/// A handle belongs to one transfer and must be closed exactly once.
pub const Access = struct {
    open: *const fn (path: []const u8, write: bool) Error!usize,
    read: *const fn (handle: usize, output: []u8) Error!usize,
    write: *const fn (handle: usize, input: []const u8) Error!void,
    close: *const fn (handle: usize) Error!void,

    pub fn native(comptime Stream: type) Access {
        const Adapter = struct {
            fn open(path: []const u8, writing: bool) Error!usize {
                return Stream.open(path, writing) catch |err| return fileError(err);
            }

            fn read(handle: usize, output: []u8) Error!usize {
                return Stream.read(handle, output) catch |err| return fileError(err);
            }

            fn write(handle: usize, input: []const u8) Error!void {
                Stream.write(handle, input) catch |err| return fileError(err);
            }

            fn close(handle: usize) Error!void {
                Stream.close(handle) catch |err| return fileError(err);
            }
        };
        return .{ .open = &Adapter.open, .read = &Adapter.read, .write = &Adapter.write, .close = &Adapter.close };
    }
};

fn fileError(err: anyerror) Error {
    return switch (err) {
        error.FileNotFound => error.UndefinedFile,
        error.FilePermissionDenied => error.InsufficientPrivilege,
        error.NotRegularFile => error.WrongObjectType,
        error.InvalidPath => error.InvalidParameterValue,
        error.PathTooLong => error.NameCapacity,
        error.UnsupportedPlatform => error.UnsupportedStatement,
        else => error.FileAccessFailure,
    };
}
