//! Allocator-free PostgreSQL ACL display for virtual catalog results.
const std = @import("std");
const types = @import("types.sig");
const array = @import("array.sig");

pub fn Acl(comptime V: type) type {
    return struct {
        const Writer = V.Arrays.Writer;

        pub fn begin(out: *V.Text, count: u32) types.Error!Writer {
            var shape: array.Shape = .{ .element = .aclitem, .ndim = @intFromBool(count != 0) };
            shape.dims[0] = count;
            return Writer.begin(out, &shape);
        }

        pub fn append(writer: *Writer, grantee: []const u8, privileges: []const u8, grantor: []const u8) types.Error!void {
            var item: V.Text = .{};
            try identifier(&item, grantee);
            try bytes(&item, "=");
            try bytes(&item, privileges);
            try bytes(&item, "/");
            try identifier(&item, grantor);
            try writer.append(&.{ .text = item });
        }

        pub fn ownerOnly(owner: []const u8, privileges: []const u8) types.Error!V.Cell {
            var out: V.Text = .{};
            var writer = try begin(&out, 1);
            try append(&writer, owner, privileges, owner);
            return .{ .array = out };
        }

        pub fn ownerAndPublic(owner: []const u8, privileges: []const u8, public: []const u8) types.Error!V.Cell {
            var out: V.Text = .{};
            var writer = try begin(&out, 2);
            try append(&writer, owner, privileges, owner);
            try append(&writer, "", public, owner);
            return .{ .array = out };
        }

        pub fn publicAndOwner(owner: []const u8, privileges: []const u8) types.Error!V.Cell {
            var out: V.Text = .{};
            var writer = try begin(&out, 2);
            try append(&writer, "", privileges, owner);
            try append(&writer, owner, privileges, owner);
            return .{ .array = out };
        }

        fn bytes(out: *V.Text, value: []const u8) types.Error!void {
            if (value.len > out.bytes.len - out.len) return error.TextCapacity;
            @memcpy(out.bytes[out.len..][0..value.len], value);
            out.len += value.len;
        }

        fn identifier(out: *V.Text, name: []const u8) types.Error!void {
            for (name) |c| {
                if (std.ascii.isAlphanumeric(c) or c == '_') continue;
                try bytes(out, "\"");
                for (name) |part| {
                    if (part == '"') try bytes(out, "\"");
                    try bytes(out, &.{part});
                }
                return bytes(out, "\"");
            }
            try bytes(out, name);
        }
    };
}
