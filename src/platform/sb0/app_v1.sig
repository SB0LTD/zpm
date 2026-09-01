//! ZPM SB0 application SDK v1.
//!
//! This module is the reusable userspace side of the consolidated SB0 ABI.
//! The runtime supplies the concrete `sb0_abi` module; applications retain no
//! allocator or platform implementation dependency.

const sb0 = @import("sb0_abi");

pub const VERSION = "1.0.0";
pub const VERSION_MAJOR: u16 = 1;
pub const VERSION_MINOR: u16 = 0;
pub const VERSION_PATCH: u16 = 0;
pub const REQUIRED_ABI_VERSION: u16 = 0;

pub const DEFAULT_NET_HANDLE: sb0.Handle = 1;
pub const DEFAULT_STORAGE_HANDLE: sb0.Handle = 2;
pub const DEFAULT_QUEUE_DEPTH: u32 = 8;

pub const InitError = error{
    QueueCreateFailed,
    SubmissionMapFailed,
    CompletionMapFailed,
};

pub const SvcResult = struct { r0: u64, r1: u64, r2: u64 };

pub fn svc(opcode: sb0.SB0OpCode, x0: u64, x1: u64, x2: u64) SvcResult {
    var r0 = x0;
    var r1 = x1;
    var r2 = x2;
    asm volatile ("svc #0"
        : [_r0] "={x0}" (r0),
          [_r1] "={x1}" (r1),
          [_r2] "={x2}" (r2),
        : [_x0] "{x0}" (r0),
          [_x1] "{x1}" (r1),
          [_x2] "{x2}" (r2),
          [_x8] "{x8}" (@as(u64, @intFromEnum(opcode))),
        : .{ .memory = true }
    );
    return .{ .r0 = r0, .r1 = r1, .r2 = r2 };
}

pub fn debugPrint(message: []const u8) void {
    _ = svc(.debug_print, @intFromPtr(message.ptr), message.len, 0);
}

pub fn yield() void {
    _ = svc(.thread_yield, 0, 0, 0);
}

pub const DeviceQueue = struct {
    device_handle: sb0.Handle,
    submission_handle: sb0.Handle,
    submission_header: *volatile sb0.RingHeader,
    submission_entries: [*]volatile sb0.SQE,
    completion_header: *volatile sb0.RingHeader,
    completion_entries: [*]volatile sb0.CQE,

    pub fn init(device_handle: sb0.Handle, depth: u32) InitError!DeviceQueue {
        const created = svc(.queue_create, depth, 0, device_handle);
        if (created.r1 != 0) return error.QueueCreateFailed;
        const submission_handle: sb0.Handle = @intCast(created.r0);
        const completion_handle: sb0.Handle = @intCast(created.r2);

        const submission = svc(.queue_map, submission_handle, 0, 0);
        if (submission.r1 != 0) return error.SubmissionMapFailed;
        const completion = svc(.queue_map, completion_handle, 0, 0);
        if (completion.r1 != 0) return error.CompletionMapFailed;

        return .{
            .device_handle = device_handle,
            .submission_handle = submission_handle,
            .submission_header = @ptrFromInt(submission.r0),
            .submission_entries = @ptrFromInt(submission.r2),
            .completion_header = @ptrFromInt(completion.r0),
            .completion_entries = @ptrFromInt(completion.r2),
        };
    }

    pub fn submit(self: *DeviceQueue, opcode: sb0.DeviceIoOp, params: [5]u64) sb0.CQE {
        const submission_index = self.submission_header.tail & self.submission_header.mask;
        self.submission_entries[submission_index] = .{
            .opcode = @intFromEnum(opcode),
            .handle = self.device_handle,
            .param = params,
        };
        releaseBarrier();
        self.submission_header.tail +%= 1;
        releaseBarrier();
        _ = svc(.queue_submit, self.submission_handle, 1, 0);
        acquireBarrier();
        const completion_index = self.completion_header.head & self.completion_header.mask;
        const result = self.completion_entries[completion_index];
        self.completion_header.head +%= 1;
        return result;
    }
};

pub const Network = struct {
    queue: DeviceQueue,

    pub fn init(device_handle: sb0.Handle) InitError!Network {
        return .{ .queue = try DeviceQueue.init(device_handle, DEFAULT_QUEUE_DEPTH) };
    }

    pub fn bind(self: *Network, port: u16, max_connections: u16) sb0.SB0Error {
        const result = self.queue.submit(.net_bind, .{ port, max_connections, 0, 0, 0 });
        return sb0.completionStatus(result.flags);
    }

    pub fn poll(self: *Network, events: []sb0.NetEvent) u32 {
        const result = self.queue.submit(.net_poll, .{
            @intFromPtr(events.ptr), events.len, 0, 0, 0,
        });
        if (sb0.completionStatus(result.flags) != .success) return 0;
        return @intCast(@as(u64, @bitCast(result.result)));
    }

    pub fn readStream(
        self: *Network,
        connection_id: u32,
        stream_id: u64,
        output: []u8,
    ) struct { bytes: u32, flags: sb0.NetStreamFlags, status: sb0.SB0Error } {
        const result = self.queue.submit(.net_stream_read, .{
            connection_id, stream_id, @intFromPtr(output.ptr), output.len, 0,
        });
        const status = sb0.completionStatus(result.flags);
        return .{
            .bytes = if (status == .success) @intCast(@as(u64, @bitCast(result.result))) else 0,
            .flags = @bitCast(@as(u16, @truncate(result.flags >> 16))),
            .status = status,
        };
    }

    pub fn writeStream(
        self: *Network,
        connection_id: u32,
        stream_id: u64,
        bytes: []const u8,
        fin: bool,
    ) u32 {
        const flags: sb0.NetWriteFlags = .{ .fin = fin };
        const result = self.queue.submit(.net_stream_write, .{
            connection_id, stream_id, @intFromPtr(bytes.ptr), bytes.len, @bitCast(flags),
        });
        if (sb0.completionStatus(result.flags) != .success) return 0;
        return @intCast(@as(u64, @bitCast(result.result)));
    }
};

pub const Storage = struct {
    queue: DeviceQueue,

    pub fn init(device_handle: sb0.Handle) InitError!Storage {
        return .{ .queue = try DeviceQueue.init(device_handle, DEFAULT_QUEUE_DEPTH) };
    }

    pub fn metadata(self: *Storage, output: *sb0.StorageMetadata) sb0.SB0Error {
        const result = self.queue.submit(.metadata, .{
            @intFromPtr(output), @sizeOf(sb0.StorageMetadata), 0, 0, 0,
        });
        return sb0.completionStatus(result.flags);
    }

    pub fn readAt(self: *Storage, offset: u64, output: []u8) sb0.SB0Error {
        const result = self.queue.submit(.read_at, .{
            offset, @intFromPtr(output.ptr), output.len, 0, 0,
        });
        return sb0.completionStatus(result.flags);
    }

    pub fn writeAt(self: *Storage, offset: u64, bytes: []const u8) sb0.SB0Error {
        const result = self.queue.submit(.write_at, .{
            offset, @intFromPtr(bytes.ptr), bytes.len, 0, 0,
        });
        return sb0.completionStatus(result.flags);
    }
};

fn releaseBarrier() void {
    asm volatile ("dmb ishst" ::: .{ .memory = true });
}

fn acquireBarrier() void {
    asm volatile ("dmb ishld" ::: .{ .memory = true });
}
