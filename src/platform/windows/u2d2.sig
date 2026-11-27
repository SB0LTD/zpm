//! U2D2 raw DYNAMIXEL serial transport. The adapter performs bus turnaround.
const io = @import("slowwire_io.sig");
const p = @import("../../core/device/dynamixel2.sig");
const xl = @import("../../core/device/xl330.sig");
pub const U2d2 = struct {
    handle: io.Handle,
    pub fn open(port: []const u8) io.Error!U2d2 {
        return .{ .handle = try io.serialBaud(port, 57600) };
    }
    pub fn close(self: *U2d2) void {
        io.close(self.handle);
    }
    pub fn bus(self: *U2d2) xl.Bus {
        return .{ .context = self, .exchange = exchange };
    }
    fn exchange(context: *anyopaque, bytes: []const u8, expected: u8, status: *p.Status) xl.Error!void {
        const self: *U2d2 = @ptrCast(@alignCast(context));
        io.purge(self.handle) catch return error.Transport;
        io.write(self.handle, bytes) catch return error.Transport;
        if (expected == 254) return;
        var receiver: p.Receiver = .{};
        var data: [256]u8 = undefined;
        const start = io.now();
        while (io.now() -% start < 100) {
            const n = io.read(self.handle, &data) catch return error.Transport;
            for (data[0..n]) |b| if (receiver.feed(b)) |packet| {
                try p.decode(packet, status);
                if (status.id != expected) return error.WrongId;
                return;
            };
            io.sleep(1);
        }
        return error.Timeout;
    }
};
