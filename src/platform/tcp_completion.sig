//! Linux one-shot socket completions with fixed caller slots and borrowed byte buffers.
//! The ring is owned by one reactor. The caller retains each socket and buffer
//! until its operation and any separately queued cancellation both complete.
const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;

pub const available = builtin.os.tag == .linux;
pub const Operation = enum { receive, send, cancel };
pub const Outcome = union(enum) {
    bytes: usize,
    eof,
    canceled,
    retry,
    cancel_accepted,
    cancel_raced,
    failed: linux.E,
};
pub const Completion = struct {
    slot: usize,
    operation: Operation,
    outcome: Outcome,
};

pub fn Queue(comptime capacity: usize) type {
    if (!available) @compileError("TCP completions require Linux");
    if (capacity == 0 or capacity > 16384) @compileError("invalid TCP completion capacity");

    return struct {
        const Self = @This();
        const cancel_tag: u64 = 1 << 63;
        const slot_mask: u64 = 0x7fff;
        const generation_mask: u64 = (cancel_tag - 1) >> 15;
        const Slot = struct {
            operation: ?Operation = null,
            generation: u64 = 0,
            length: usize = 0,
            canceling: bool = false,

            fn token(slot: *const Slot, index: usize) u64 {
                return (slot.generation << 15) | @as(u64, @intCast(index));
            }
        };

        ring: ?linux.IoUring = null,
        slots: [capacity]Slot = @splat(.{}),

        /// Probe setup on the current kernel before routing sockets to the
        /// ring. PermissionDenied or SystemOutdated can retain poll transport.
        pub fn init() !Self {
            const entries = try std.math.ceilPowerOfTwo(u16, @intCast(capacity * 2));
            return .{ .ring = try linux.IoUring.init(entries, 0) };
        }

        /// Closing with pending operations would cut short the caller's
        /// buffer ownership contract. Cancel, submit and collect first.
        pub fn deinit(self: *Self) !void {
            for (&self.slots) |*slot| if (slot.operation != null or slot.canceling) return error.PendingSocketOperations;
            if (self.ring) |*ring| ring.deinit();
            self.ring = null;
        }

        pub fn reusable(self: *const Self, index: usize) bool {
            return index < capacity and self.slots[index].operation == null and !self.slots[index].canceling;
        }

        fn queue(self: *Self, index: usize, fd: linux.fd_t, comptime operation: Operation, buffer: anytype) !void {
            const ring = if (self.ring) |*ring| ring else return error.SocketRingClosed;
            if (index >= capacity or fd < 0 or buffer.len == 0 or buffer.len > 0x7fffffff) return error.InvalidSocketOperation;
            if (!self.reusable(index)) return error.SocketSlotBusy;
            const slot = &self.slots[index];
            const generation = (slot.generation + 1) & generation_mask;
            const token = (generation << 15) | @as(u64, @intCast(index));
            switch (operation) {
                .receive => _ = try ring.recv(token, fd, .{ .buffer = buffer }, 0),
                .send => _ = try ring.send(token, fd, buffer, linux.MSG.NOSIGNAL),
                .cancel => unreachable,
            }
            slot.generation = generation;
            slot.operation = operation;
            slot.length = buffer.len;
        }

        pub fn receive(self: *Self, index: usize, fd: linux.fd_t, buffer: []u8) !void {
            try self.queue(index, fd, .receive, buffer);
        }

        /// On a partial completion the caller can submit the unwritten
        /// suffix with the same slot once all outstanding CQEs are consumed.
        pub fn send(self: *Self, index: usize, fd: linux.fd_t, buffer: []const u8) !void {
            try self.queue(index, fd, .send, buffer);
        }

        /// True means a cancellation request was queued. Its CQE never
        /// substitutes for the original operation's terminal CQE.
        pub fn cancel(self: *Self, index: usize) !bool {
            const ring = if (self.ring) |*ring| ring else return error.SocketRingClosed;
            if (index >= capacity) return error.InvalidSocketOperation;
            const slot = &self.slots[index];
            if (slot.operation == null or slot.canceling) return false;
            const token = slot.token(index);
            _ = try ring.cancel(token | cancel_tag, token, 0);
            slot.canceling = true;
            return true;
        }

        pub fn submit(self: *Self) !u32 {
            const ring = if (self.ring) |*ring| ring else return error.SocketRingClosed;
            return ring.submit();
        }

        /// Raw completion scratch is caller-owned and may be reused once
        /// this returns. A nonzero wait asks for at least one completion.
        pub fn complete(self: *Self, raw: []linux.io_uring_cqe, out: []Completion, wait: bool) !usize {
            const ring = if (self.ring) |*ring| ring else return error.SocketRingClosed;
            const room = @min(raw.len, out.len);
            if (room == 0) return error.InvalidSocketOperation;
            const count = try ring.copy_cqes(raw[0..room], @intFromBool(wait));
            for (raw[0..count], out[0..count]) |event, *completion| completion.* = try self.convert(event);
            return count;
        }

        fn convert(self: *Self, event: linux.io_uring_cqe) !Completion {
            if (event.flags & linux.IORING_CQE_F_MORE != 0) return error.InvalidSocketCompletion;
            const index: usize = @intCast(event.user_data & slot_mask);
            if (index >= capacity) return error.InvalidSocketCompletion;
            const slot = &self.slots[index];
            if (event.user_data & ~cancel_tag != slot.token(index)) return error.InvalidSocketCompletion;
            if (event.user_data & cancel_tag != 0) {
                if (!slot.canceling) return error.InvalidSocketCompletion;
                slot.canceling = false;
                const outcome: Outcome = switch (event.err()) {
                    .SUCCESS => .cancel_accepted,
                    .NOENT, .ALREADY => .cancel_raced,
                    else => |code| .{ .failed = code },
                };
                return .{ .slot = index, .operation = .cancel, .outcome = outcome };
            }
            const operation = slot.operation orelse return error.InvalidSocketCompletion;
            const outcome: Outcome = if (event.res > 0) positive: {
                const length: usize = @intCast(event.res);
                if (length > slot.length) return error.InvalidSocketCompletion;
                break :positive .{ .bytes = length };
            } else if (event.res == 0) zero: {
                if (operation != .receive) return error.InvalidSocketCompletion;
                break :zero .eof;
            } else switch (event.err()) {
                .CANCELED => .canceled,
                .AGAIN, .INTR => .retry,
                else => |code| .{ .failed = code },
            };
            slot.operation = null;
            return .{ .slot = index, .operation = operation, .outcome = outcome };
        }
    };
}
