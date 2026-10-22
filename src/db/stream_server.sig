//! Allocator-free protocol sessions over a caller-supplied byte stream.
//! The application owns the database, session, buffers and transport. A transport
//! provides read([]u8)!usize (zero is EOF) and writeAll([]const u8)!void.
//! This is suitable for delegated channels, UART and already accepted sockets;
//! it does not promise network listening, authentication or durable storage.
pub fn Server(comptime Database: type, comptime Protocol: type, comptime input_capacity: usize) type {
    if (input_capacity == 0) @compileError("stream input capacity must be nonzero");
    return struct {
        const Self = @This();
        input: [input_capacity]u8 = undefined,
        output: [Protocol.responseCapacity()]u8 = undefined,
        used: usize = 0,

        /// Serve one connection. All returned errors close that connection;
        /// applications must call their database disconnect/rollback policy.
        pub fn run(self: *Self, io: anytype, database: *Database, session: *Protocol) !void {
            self.used = 0;
            while (true) {
                if (self.used != 0) {
                    const reply = try session.handle(database, self.input[0..self.used], &self.output);
                    if (reply.consumed > self.used or reply.written > self.output.len) return error.InvalidProtocolReply;
                    if (reply.consumed == 0 and reply.written != 0) return error.InvalidProtocolReply;
                    if (reply.written != 0) try io.writeAll(self.output[0..reply.written]);
                    if (reply.close) return;
                    if (reply.consumed != 0) {
                        const remaining = self.used - reply.consumed;
                        // Explicit forward copy supports overlapping slices.
                        for (0..remaining) |i| self.input[i] = self.input[reply.consumed + i];
                        self.used = remaining;
                        continue;
                    }
                }
                if (self.used == self.input.len) return error.RequestTooLarge;
                const count = try io.read(self.input[self.used..]);
                if (count > self.input.len - self.used) return error.InvalidReadCount;
                if (count == 0) {
                    if (self.used != 0) return error.UnexpectedEndOfStream;
                    return;
                }
                self.used += count;
            }
        }
    };
}
