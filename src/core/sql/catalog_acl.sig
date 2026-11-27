//! Allocator-free PostgreSQL ACL display for virtual catalog results.
const std = @import("std");
const types = @import("types.sig");
const array = @import("array.sig");

pub fn Acl(comptime V: type) type {
    return struct {
        const Writer = V.Arrays.Writer;

        fn shapeFor(count: u32) array.Shape {
            var shape: array.Shape = .{ .element = .aclitem, .ndim = @intFromBool(count != 0) };
            shape.dims[0] = count;
            return shape;
        }

        pub fn begin(out: *V.Text, count: u32) types.Error!Writer {
            return Writer.begin(out, &shapeFor(count));
        }

        pub fn append(writer: *Writer, grantee: []const u8, privileges: []const u8, grantor: []const u8) types.Error!void {
            var item: V.Text = .{};
            var output: Output = .{ .buffer = &item.bytes };
            try output.item(grantee, privileges, grantor);
            item.len = output.len;
            try writer.append(&.{ .text = item });
        }

        /// The catalog uses the same typed array layout with a variable
        /// backing span. No role bytes are clipped to an inline cell.
        pub const CatalogWriter = struct {
            out: Output,
            values: ?*types.ValueBytes,

            pub fn start(inline_buffer: []u8, values: ?*types.ValueBytes, count: u32) types.Error!CatalogWriter {
                const arena = if (comptime V.Text.inline_capacity >= @sizeOf(usize)) values else null;
                const space = if (arena) |backing| backing.available() else inline_buffer;
                return .{
                    .out = .{ .buffer = space, .len = try V.Arrays.writeHeader(space, &shapeFor(count)) },
                    .values = arena,
                };
            }

            pub fn add(self: *CatalogWriter, grantee: []const u8, privileges: []const u8, grantor: []const u8) types.Error!void {
                const begin_item = self.out.len;
                try self.out.bytes(&.{ 1, 0, 0 });
                try self.out.item(grantee, privileges, grantor);
                const len = self.out.len - begin_item - 3;
                if (len > 0xffff) return error.TextCapacity;
                std.mem.writeInt(u16, self.out.buffer[begin_item + 1 ..][0..2], @intCast(len), .little);
            }

            pub fn finish(self: *CatalogWriter) V.Cell {
                if (self.out.len > V.Text.inline_capacity) self.values.?.used += self.out.len;
                return .{ .array = V.Text.fromValueBytes(self.out.buffer[0..self.out.len]) };
            }
        };

        pub fn catalogOwner(owner: []const u8, privileges: []const u8, values: ?*types.ValueBytes) types.Error!V.Cell {
            return catalogDefaults(owner, privileges, null, values);
        }

        pub fn catalogDefaults(owner: []const u8, privileges: []const u8, public: ?[]const u8, values: ?*types.ValueBytes) types.Error!V.Cell {
            var inline_buffer: [V.Text.inline_capacity]u8 = undefined;
            var writer = try CatalogWriter.start(&inline_buffer, values, if (public == null) 1 else 2);
            if (public) |rights| try writer.add("", rights, owner);
            try writer.add(owner, privileges, owner);
            return writer.finish();
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

        pub fn publicAndOwner(owner: []const u8, privileges: []const u8, public: []const u8) types.Error!V.Cell {
            var out: V.Text = .{};
            var writer = try begin(&out, 2);
            try append(&writer, "", public, owner);
            try append(&writer, owner, privileges, owner);
            return .{ .array = out };
        }

        pub fn empty() types.Error!V.Cell {
            var out: V.Text = .{};
            _ = try begin(&out, 0);
            return .{ .array = out };
        }

        const Output = struct {
            buffer: []u8,
            len: usize = 0,

            fn bytes(out: *Output, value: []const u8) types.Error!void {
                if (value.len > out.buffer.len - out.len) return error.TextCapacity;
                @memcpy(out.buffer[out.len..][0..value.len], value);
                out.len += value.len;
            }

            fn item(out: *Output, grantee: []const u8, privileges: []const u8, grantor: []const u8) types.Error!void {
                try out.identifier(grantee);
                try out.bytes("=");
                try out.bytes(privileges);
                try out.bytes("/");
                try out.identifier(grantor);
            }

            fn identifier(out: *Output, name: []const u8) types.Error!void {
                for (name) |c| {
                    if (std.ascii.isAlphanumeric(c) or c == '_') continue;
                    try out.bytes("\"");
                    for (name) |part| {
                        if (part == '"') try out.bytes("\"");
                        try out.bytes(&.{part});
                    }
                    return out.bytes("\"");
                }
                try out.bytes(name);
            }
        };
    };
}
