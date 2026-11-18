//! Linux one-shot socket completions with fixed caller slots and borrowed byte buffers.
//! The ring is owned by one reactor. The caller retains each socket and buffer
//! until its operation and any separately queued cancellation both complete.
const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;

pub const available = builtin.os.tag == .linux;
pub const Operation = enum { receive, send, cancel, wake };
pub const TimedWait = enum { ready, yielded, unsupported };
pub const Outcome = union(enum) {
    bytes: usize,
    eof,
    canceled,
    retry,
    cancel_accepted,
    cancel_raced,
    notified,
    failed: linux.E,
};
pub const Completion = struct {
    slot: usize,
    operation: Operation,
    outcome: Outcome,
};

pub fn Queue(comptime capacity: usize) type {
    if (!available) @compileError("TCP completions require Linux");
    if (capacity == 0 or capacity > 16383) @compileError("invalid TCP completion capacity");

    return struct {
        const Self = @This();
        const cancel_tag: u64 = 1 << 63;
        const slot_mask: u64 = 0x7fff;
        const wake_token = slot_mask;
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
        wake_supported: bool = false,
        wake_armed: bool = false,
        wake_canceling: bool = false,

        /// Probe setup on the current kernel before routing sockets to the
        /// ring. PermissionDenied or SystemOutdated can retain poll transport.
        pub fn init() !Self {
            const entries = try std.math.ceilPowerOfTwo(u16, @intCast(capacity * 2 + 1));
            var ring = try linux.IoUring.init(entries, 0);
            errdefer ring.deinit();
            const probe = try ring.get_probe();
            if (!probe.is_supported(.RECV) or !probe.is_supported(.SEND) or !probe.is_supported(.ASYNC_CANCEL))
                return error.SocketOperationsUnsupported;
            return .{ .ring = ring, .wake_supported = probe.is_supported(.POLL_ADD) };
        }

        /// Closing with pending operations would cut short the caller's
        /// buffer ownership contract. Cancel, submit and collect first.
        pub fn deinit(self: *Self) !void {
            if (self.wakePending()) return error.PendingSocketOperations;
            for (&self.slots) |*slot| if (slot.operation != null or slot.canceling) return error.PendingSocketOperations;
            if (self.ring) |*ring| ring.deinit();
            self.ring = null;
        }

        pub fn reusable(self: *const Self, index: usize) bool {
            return index < capacity and self.slots[index].operation == null and !self.slots[index].canceling;
        }

        fn validateSubmission(self: *const Self, index: usize, fd: linux.fd_t, length: usize) !void {
            if (index >= capacity or fd < 0 or length == 0 or length > 0x7fffffff) return error.InvalidSocketOperation;
            if (!self.reusable(index)) return error.SocketSlotBusy;
        }

        fn queue(self: *Self, index: usize, fd: linux.fd_t, comptime operation: Operation, buffer: anytype) !*linux.io_uring_sqe {
            const ring = if (self.ring) |*ring| ring else return error.SocketRingClosed;
            try self.validateSubmission(index, fd, buffer.len);
            const slot = &self.slots[index];
            const generation = (slot.generation + 1) & generation_mask;
            const token = (generation << 15) | @as(u64, @intCast(index));
            const sqe = switch (operation) {
                .receive => try ring.recv(token, fd, .{ .buffer = buffer }, 0),
                .send => try ring.send(token, fd, buffer, linux.MSG.NOSIGNAL),
                .cancel, .wake => unreachable,
            };
            slot.generation = generation;
            slot.operation = operation;
            slot.length = buffer.len;
            return sqe;
        }

        pub fn receive(self: *Self, index: usize, fd: linux.fd_t, buffer: []u8) !void {
            _ = try self.queue(index, fd, .receive, buffer);
        }

        /// On a partial completion the caller can submit the unwritten
        /// suffix with the same slot once all outstanding CQEs are consumed.
        pub fn send(self: *Self, index: usize, fd: linux.fd_t, buffer: []const u8) !void {
            _ = try self.queue(index, fd, .send, buffer);
        }

        /// Queue the reply and next input in one soft-linked submission,
        /// retaining a distinct CQE and lease for each buffer. A short send
        /// may still start the receive. The caller must finish all reply
        /// bytes before acting on the next input, even if RX completes first.
        pub fn sendAndReceive(self: *Self, tx: usize, rx: usize, fd: linux.fd_t,
            output: []const u8, input: []u8) !void {
            const ring = if (self.ring) |*ring| ring else return error.SocketRingClosed;
            try self.validateSubmission(tx, fd, output.len);
            try self.validateSubmission(rx, fd, input.len);
            if (tx == rx) return error.InvalidSocketOperation;
            const out_start = @intFromPtr(output.ptr);
            const in_start = @intFromPtr(input.ptr);
            const out_end = @addWithOverflow(out_start, output.len);
            const in_end = @addWithOverflow(in_start, input.len);
            if (out_end[1] != 0 or in_end[1] != 0 or
                (out_start < in_end[0] and in_start < out_end[0])) return error.InvalidSocketOperation;
            // Only this owner queues SQEs. The kernel can only free entries
            // between the capacity proof and these two reservations.
            if (ring.sq.sqes.len - ring.sq_ready() < 2) return error.SubmissionQueueFull;
            const first = try self.queue(tx, fd, .send, output);
            _ = self.queue(rx, fd, .receive, input) catch unreachable;
            first.flags |= linux.IOSQE_IO_LINK;
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

        /// Arm one external wake descriptor. The reactor consumes the signal
        /// and rearms the descriptor after its terminal completion.
        pub fn armWake(self: *Self, fd: linux.fd_t) !bool {
            const ring = if (self.ring) |*ring| ring else return error.SocketRingClosed;
            if (!self.wake_supported) return false;
            if (fd < 0 or self.wakePending()) return error.InvalidSocketOperation;
            _ = try ring.poll_add(wake_token, fd, linux.POLL.IN);
            self.wake_armed = true;
            return true;
        }

        pub fn cancelWake(self: *Self) !bool {
            const ring = if (self.ring) |*ring| ring else return error.SocketRingClosed;
            if (!self.wake_armed or self.wake_canceling) return false;
            _ = try ring.cancel(wake_token | cancel_tag, wake_token, 0);
            self.wake_canceling = true;
            return true;
        }

        pub fn wakePending(self: *const Self) bool {
            return self.wake_armed or self.wake_canceling;
        }

        fn cancelOutcome(event: linux.io_uring_cqe) Outcome {
            return switch (event.err()) {
                .SUCCESS => .cancel_accepted,
                .NOENT, .ALREADY => .cancel_raced,
                else => |code| .{ .failed = code },
            };
        }

        fn convertWake(self: *Self, event: linux.io_uring_cqe) !Completion {
            if (event.user_data & cancel_tag != 0) {
                if (!self.wake_canceling) return error.InvalidSocketCompletion;
                self.wake_canceling = false;
                return .{ .slot=capacity, .operation=.wake, .outcome=cancelOutcome(event) };
            }
            if (!self.wake_armed) return error.InvalidSocketCompletion;
            const outcome: Outcome = if (event.res >= 0)
                (if (event.res & linux.POLL.IN != 0) .notified else .{.failed=.IO})
            else switch (event.err()) {
                .CANCELED => .canceled,
                else => |code| .{.failed=code},
            };
            self.wake_armed = false;
            return .{.slot=capacity,.operation=.wake,.outcome=outcome};
        }

        /// Pollable completion descriptor. The queue keeps ownership of it.
        pub fn descriptor(self: *const Self) linux.fd_t {
            return if (self.ring) |*ring| ring.fd else -1;
        }

        /// Submit and wait in one syscall when the kernel has EXT_ARG.
        /// Yielded includes expiry and interruption. User buffers remain
        /// owned by pending requests until their terminal CQEs.
        pub fn submitAndWait(self: *Self, duration_ns: u64) !TimedWait {
            const ring = if (self.ring) |*ring| ring else return error.SocketRingClosed;
            if (duration_ns == 0) return error.InvalidSocketOperation;
            if (ring.features & linux.IORING_FEAT_EXT_ARG == 0) return .unsupported;
            const remaining = ring.flush_sq();
            if (remaining == 0 and ring.cq_ready() != 0) return .ready;
            const duration: linux.kernel_timespec = .{ .sec = @intCast(duration_ns / 1000000000),
                .nsec = @intCast(duration_ns % 1000000000) };
            const extended: linux.io_uring_getevents_arg = .{ .sigmask = 0, .sigmask_sz = 0,
                .pad = 0, .ts = @intFromPtr(&duration) };
            // The pinned standard enter wrapper only accepts a signal mask.
            const result = linux.syscall6(.io_uring_enter, @intCast(ring.fd), remaining, 1,
                linux.IORING_ENTER_GETEVENTS | linux.IORING_ENTER_EXT_ARG, @intFromPtr(&extended), @sizeOf(@TypeOf(extended)));
            switch (linux.errno(result)) {
                .SUCCESS, .TIME, .INTR => return if (ring.cq_ready() != 0) .ready else .yielded,
                .INVAL, .OPNOTSUPP, .PERM, .NOSYS => return .unsupported,
                else => return error.TimedSocketWaitFailed,
            }
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
            if (event.user_data & ~cancel_tag == wake_token) return self.convertWake(event);
            const index: usize = @intCast(event.user_data & slot_mask);
            if (index >= capacity) return error.InvalidSocketCompletion;
            const slot = &self.slots[index];
            if (event.user_data & ~cancel_tag != slot.token(index)) return error.InvalidSocketCompletion;
            if (event.user_data & cancel_tag != 0) {
                if (!slot.canceling) return error.InvalidSocketCompletion;
                slot.canceling = false;
                return .{ .slot = index, .operation = .cancel, .outcome = cancelOutcome(event) };
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
