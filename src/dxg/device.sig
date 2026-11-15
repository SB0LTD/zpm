//! @zpm/dxg device — the GPU behind /dev/dxg as an nvidia.device.Device, so
//! zpm's NVIDIA users run on it unchanged: the GPU-neutral layer
//! (gpu.nvidia_device.over: KIR compiled for sm_120, its self-test),
//! lfm3_nv's forward pass, the 3D engine's renderer.
//!
//! Buffers come out of system memory the caller gives (`init`: page-aligned,
//! shared or private), each one its own allocation the GPU maps (rounded up
//! to 64 KiB); the CPU's view is the same bytes, so toDevice and fromDevice
//! are barriers only. A submission is Gpu.submit; its fence, Gpu's.
//!
//! Allocation-free: the block list is fixed (MAX_BUFFERS), the memory the
//! caller's.

const std = @import("std");
const nvidia = @import("nvidia");
const nvd = nvidia.device;
const gpu_mod = @import("gpu.sig");
const Gpu = gpu_mod.Gpu;

pub const MAX_BUFFERS = 1024;
const UNIT: usize = 64 << 10;

pub const DxgDevice = struct {
    gpu: *Gpu,
    memory: []align(4096) u8,
    /// The memory's pieces in address order: each free or a buffer's.
    blocks: [MAX_BUFFERS]Block = undefined,
    n: usize = 0,
    lost: bool = false,

    const Block = struct { off: usize, len: usize, used: bool, handle: u32 = 0, va: u64 = 0 };

    pub fn init(d: *DxgDevice, g: *Gpu, memory: []align(4096) u8) void {
        const len = memory.len / UNIT * UNIT;
        d.* = .{ .gpu = g, .memory = memory[0..len] };
        d.blocks[0] = .{ .off = 0, .len = len, .used = false };
        d.n = 1;
    }

    pub fn device(d: *DxgDevice) nvd.Device {
        return .{ .ctx = d, .vtable = &vtable };
    }

    const vtable = nvd.Device.VTable{
        .alloc = alloc,
        .free = free,
        .submit = submit,
        .wait = wait,
        .toDevice = barrier,
        .fromDevice = barrier,
    };

    fn alloc(ctx: *anyopaque, size: usize) ?nvd.Buffer {
        const d: *DxgDevice = @ptrCast(@alignCast(ctx));
        const want = std.mem.alignForward(usize, @max(size, 1), UNIT);
        for (d.blocks[0..d.n], 0..) |b, i| {
            if (b.used or b.len < want) continue;
            if (b.len > want) {
                if (d.n == MAX_BUFFERS) return null;
                std.mem.copyBackwards(Block, d.blocks[i + 2 .. d.n + 1], d.blocks[i + 1 .. d.n]);
                d.blocks[i + 1] = .{ .off = b.off + want, .len = b.len - want, .used = false };
                d.n += 1;
            }
            const cpu: []align(4096) u8 = @alignCast(d.memory[b.off..][0..want]);
            const r = d.gpu.mapSystem(cpu) catch {
                // (merged back by the next free of a neighbour; mark free)
                d.blocks[i] = .{ .off = b.off, .len = want, .used = false };
                return null;
            };
            d.blocks[i] = .{ .off = b.off, .len = want, .used = true, .handle = r.handle, .va = r.va };
            return .{ .va = r.va, .cpu = cpu[0..size], .handle = r.handle };
        }
        return null;
    }

    fn free(ctx: *anyopaque, buf: nvd.Buffer) void {
        const d: *DxgDevice = @ptrCast(@alignCast(ctx));
        for (d.blocks[0..d.n], 0..) |*b, i| {
            if (!b.used or b.handle != buf.handle) continue;
            d.gpu.release(.{ .handle = b.handle });
            b.used = false;
            b.handle = 0;
            // merge with free neighbours
            if (i + 1 < d.n and !d.blocks[i + 1].used) {
                b.len += d.blocks[i + 1].len;
                std.mem.copyForwards(Block, d.blocks[i + 1 .. d.n - 1], d.blocks[i + 2 .. d.n]);
                d.n -= 1;
            }
            if (i > 0 and !d.blocks[i - 1].used) {
                d.blocks[i - 1].len += b.len;
                std.mem.copyForwards(Block, d.blocks[i .. d.n - 1], d.blocks[i + 1 .. d.n]);
                d.n -= 1;
            }
            return;
        }
    }

    fn submit(ctx: *anyopaque, pb: nvd.Buffer, dwords: u32) nvd.Error!nvd.Fence {
        const d: *DxgDevice = @ptrCast(@alignCast(ctx));
        if (d.lost) return error.DeviceLost;
        barrierNow();
        return d.gpu.submit(pb.va, dwords) catch error.SubmitFailed;
    }

    fn wait(ctx: *anyopaque, f: nvd.Fence, timeout_us: u64) nvd.Error!void {
        const d: *DxgDevice = @ptrCast(@alignCast(ctx));
        d.gpu.wait(f, timeout_us) catch return error.Timeout;
        barrierNow();
    }

    fn barrier(_: *anyopaque, _: nvd.Buffer, _: usize, _: usize) void {
        barrierNow();
    }
};

var fence_word: u32 = 0;
fn barrierNow() void {
    _ = @atomicRmw(u32, &fence_word, .Add, 0, .seq_cst);
}

test "buffers are carved in 64 KiB pieces and merge back (no GPU: the list only)" {
    var d: DxgDevice = undefined;
    var mem: [4 * UNIT]u8 align(4096) = undefined;
    d.blocks[0] = .{ .off = 0, .len = mem.len, .used = false };
    d.n = 1;
    d.memory = &mem;
    // (alloc needs a GPU; check the merge on hand-made blocks)
    d.blocks[0] = .{ .off = 0, .len = UNIT, .used = true, .handle = 1 };
    d.blocks[1] = .{ .off = UNIT, .len = UNIT, .used = true, .handle = 2 };
    d.blocks[2] = .{ .off = 2 * UNIT, .len = 2 * UNIT, .used = false };
    d.n = 3;
    var g: Gpu = .{};
    d.gpu = &g;
    DxgDevice.free(&d, .{ .handle = 2 });
    try std.testing.expectEqual(@as(usize, 2), d.n);
    try std.testing.expectEqual(@as(usize, 3 * UNIT), d.blocks[1].len);
    DxgDevice.free(&d, .{ .handle = 1 });
    try std.testing.expectEqual(@as(usize, 1), d.n);
    try std.testing.expectEqual(@as(usize, 4 * UNIT), d.blocks[0].len);
}
