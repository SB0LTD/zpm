//! Layer 0 caller-owned 3D triangle scene, usable by native GL or GLES adapters.
pub const Vec3 = extern struct { x: f32, y: f32, z: f32 };
pub const ColoredVertex = extern struct { position: Vec3, color: [4]f32 };
pub const Color = struct { r: f32, g: f32, b: f32 };
pub const Triangle = struct { vertices: [3]Vec3, color: Color };
pub const Screen = struct { x: f32, y: f32, depth: f32 };
pub const Camera = struct {
    position: Vec3 = .{ .x = 0, .y = 8, .z = -12 },
    yaw: f32 = 0, pitch: f32 = -0.5, focal: f32 = 1.3,
    pub fn project(self: Camera, point: Vec3, aspect: f32) ?Screen {
        const dx = point.x - self.position.x;
        const dy = point.y - self.position.y;
        const dz = point.z - self.position.z;
        const x = dx * @cos(self.yaw) - dz * @sin(self.yaw);
        const forward = dx * @sin(self.yaw) + dz * @cos(self.yaw);
        const y = dy * @cos(self.pitch) - forward * @sin(self.pitch);
        const depth = dy * @sin(self.pitch) + forward * @cos(self.pitch);
        if (depth <= 0.1 or aspect <= 0) return null;
        return .{ .x = x * self.focal / depth / aspect, .y = y * self.focal / depth, .depth = depth };
    }
};
pub fn Scene(comptime capacity: usize) type {
    return struct {
        const Self = @This();
        triangles: [capacity]Triangle = undefined, count: usize = 0,
        pub fn writeVertices(self: *const Self, output: []ColoredVertex) error{Capacity}!usize {
            if (output.len/3 < self.count) return error.Capacity;
            var index: usize = 0;
            for (self.triangles[0..self.count]) |triangle| { for (triangle.vertices) |position| {
                output[index] = .{ .position = position, .color = .{triangle.color.r,triangle.color.g,triangle.color.b,1} };
                index += 1;
            } }
            return index;
        }
        pub fn cube(self: *Self, center: Vec3, half: Vec3, color: Color) error{Capacity}!void {
            if (capacity - self.count < 12) return error.Capacity;
            const corners = [_]Vec3{
                .{ .x = center.x-half.x, .y = center.y-half.y, .z = center.z-half.z },
                .{ .x = center.x+half.x, .y = center.y-half.y, .z = center.z-half.z },
                .{ .x = center.x+half.x, .y = center.y+half.y, .z = center.z-half.z },
                .{ .x = center.x-half.x, .y = center.y+half.y, .z = center.z-half.z },
                .{ .x = center.x-half.x, .y = center.y-half.y, .z = center.z+half.z },
                .{ .x = center.x+half.x, .y = center.y-half.y, .z = center.z+half.z },
                .{ .x = center.x+half.x, .y = center.y+half.y, .z = center.z+half.z },
                .{ .x = center.x-half.x, .y = center.y+half.y, .z = center.z+half.z },
            };
            const faces = [_][3]u8{ .{0,1,2}, .{0,2,3}, .{4,6,5}, .{4,7,6}, .{0,4,5}, .{0,5,1}, .{3,2,6}, .{3,6,7}, .{0,3,7}, .{0,7,4}, .{1,5,6}, .{1,6,2} };
            for (faces, 0..) |face, i| {
                const shade: f32 = if (i < 4) 0.8 else if (i < 8) 1 else 0.65;
                self.triangles[self.count] = .{ .vertices = .{ corners[face[0]], corners[face[1]], corners[face[2]] }, .color = .{ .r = color.r*shade, .g = color.g*shade, .b = color.b*shade } };
                self.count += 1;
            }
        }
    };
}
