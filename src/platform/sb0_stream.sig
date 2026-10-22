//! Native consolidated SB0 stream primitives, without a hosted OS or heap.
//! Channel is a delegated process capability (stdio profile, handle 1).
//! Uart is the QEMU virt PL011 device and requires privileged SB0K context.
//! Neither transport supplies TCP, durable storage or cryptographic entropy.
const builtin = @import("builtin");
const Result = extern struct { value: u64 = 0, status: u64 = 0 };
extern fn zpmSb0StreamTrap(u64, u64, u64, u64, *Result) callconv(.c) void;

comptime {
    if (builtin.cpu.arch == .aarch64) {
        asm (
            \\.global zpmSb0StreamTrap
            \\.type zpmSb0StreamTrap, %function
            \\.p2align 2
            \\zpmSb0StreamTrap:
            \\  mov x9, x4
            \\  mov x8, x0
            \\  mov x0, x1
            \\  mov x1, x2
            \\  mov x2, x3
            \\  svc #0
            \\  str x0, [x9]
            \\  str x1, [x9, #8]
            \\  ret
        );
    }
}

fn trap(op: u64, a: u64, b: u64, c: u64) Result {
    var result: Result = .{};
    if (builtin.cpu.arch == .aarch64) zpmSb0StreamTrap(op, a, b, c, &result);
    return result;
}

pub fn debug(message: []const u8) void {
    _ = trap(0x0f00, @intFromPtr(message.ptr), message.len, 0);
}

pub fn processExit(code: u64) noreturn {
    _ = trap(0, code, 0, 0);
    park();
}

pub fn park() noreturn {
    while (true) {
        if (builtin.cpu.arch == .aarch64) asm volatile ("wfe");
    }
}

pub const Channel = struct {
    handle: u64 = 1,
    pub fn read(self: *Channel, output: []u8) !usize {
        if (output.len == 0) return 0;
        while (true) {
            const result = trap(0x0602, self.handle, @intFromPtr(output.ptr), output.len);
            if (result.status == 0) {
                if (result.value == 0) continue;
                if (result.value > output.len) return error.InvalidChannelRead;
                return @intCast(result.value);
            }
            if (result.status != 11) return error.ChannelClosed;
            _ = trap(0x0403, 0, 0, 0); // thread_yield
        }
    }
    pub fn writeAll(self: *Channel, bytes: []const u8) !void {
        var offset: usize = 0;
        while (offset < bytes.len) {
            const result = trap(0x0601, self.handle, @intFromPtr(bytes.ptr + offset), bytes.len - offset);
            if (result.status == 11) {
                _ = trap(0x0403, 0, 0, 0);
                continue;
            }
            if (result.status != 0 or result.value == 0 or result.value > bytes.len - offset) return error.ChannelClosed;
            offset += @intCast(result.value);
        }
    }
};

/// Privileged PL011 byte stream for the QEMU virt SB0K boot profile.
pub const Uart = struct {
    fn reg(offset: usize) *volatile u32 {
        return @ptrFromInt(0x09000000 + offset);
    }
    pub fn writeAll(_: *Uart, bytes: []const u8) !void {
        for (bytes) |byte| {
            while (reg(0x18).* & (1 << 5) != 0) {}
            reg(0).* = byte;
        }
    }
    pub fn read(_: *Uart, output: []u8) !usize {
        if (output.len == 0) return 0;
        while (reg(0x18).* & (1 << 4) != 0) {}
        output[0] = @truncate(reg(0).*);
        var count: usize = 1;
        while (count < output.len and reg(0x18).* & (1 << 4) == 0) : (count += 1) output[count] = @truncate(reg(0).*);
        return count;
    }
};
