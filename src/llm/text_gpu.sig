//! Optional resident CUDA matrix backend for the storage-neutral Qwen executor.
//! All host staging, cache entries and device arenas belong to the caller.
//! An optional F16 cache expands GGML rows with the shared native dequantizer
//! and uses F32 cuBLAS accumulation/output; the default packed mode
//! keeps original Q4_K/Q6_K weights resident and performs native PTX F32 dots.
//! There are no allocations, model globals, per-operation loads, or CPU retry.
const std = @import("std");
const gguf = @import("gguf");
const quantized = @import("quantized_linear");
const ptx = @import("text_gpu_ptx.sig");
pub const cuda = @import("../matmul/cuda.sig");
pub const Error = quantized.Error || error{
    InvalidTensor,
    Capacity,
    StorageFailure,
    UnsupportedType,
    NonFinite,
    GpuUnavailable,
    GpuFailure,
    Cancelled,
    Failed,
    ArithmeticOverflow,
    InvalidStorage,
    AliasedStorage,
};

pub const CacheEntry = struct {
    file_offset: u64 = 0,
    encoded_bytes: u64 = 0,
    ggml_type: u32 = 0,
    columns: usize = 0,
    rows: usize = 0,
    device: u64 = 0,
};
pub const Mode = enum { expanded_f16, quantized };
pub const Storage = struct {
    weight_arena: u64,
    weight_bytes: usize,
    device_scratch: u64,
    scratch_bytes: usize,
    entries: []CacheEntry,
    /// Expanded-F16 mode only: at least the largest matrix input dimension.
    decoded_row: []f32 = &.{},
    /// Expanded-F16 mode only, when the source cannot map an encoded row.
    encoded_row: []u8 = &.{},
    /// Packed mode uses these bytes as upload staging. Expanded-F16 mode
    /// requires at least one largest matrix row, in halves.
    upload_half: []f16,
    /// Expanded-F16 mode only: at least the largest matrix input dimension.
    input_half: []f16 = &.{},
    mode: Mode = .quantized,
    /// Eight independent output rows per block. Set false to compare the
    /// alternative 256-thread reduction for one output row per block.
    warp_rows: bool = true,
};

/// One immutable model source, one exclusive CUDA context and caller storage.
/// Initialize `cuda` before execution and keep it alive through `deinit`.
/// This backend is synchronous and must not be shared by concurrent executors.
/// Mutating the source or reusing its device arena requires `reset` first.
pub const Backend = struct {
    source: gguf.Source,
    storage: Storage,
    entry_count: usize = 0,
    arena_used: usize = 0,
    failure: ?Error = null,
    matrix_calls: u64 = 0,
    matrices_uploaded: u64 = 0,
    bytes_uploaded: u64 = 0,
    cancel_context: ?*anyopaque = null,
    is_cancelled: ?*const fn (*anyopaque) bool = null,
    kernel_module: ?cuda.CUmodule = null,
    packed_kernel: ?cuda.CUfunction = null,

    pub fn init(source: gguf.Source, storage: Storage) Error!Backend {
        if (storage.weight_arena == 0 or storage.weight_bytes == 0 or
            storage.device_scratch == 0 or storage.scratch_bytes == 0 or
            storage.entries.len == 0 or storage.upload_half.len == 0)
            return error.Capacity;
        if (storage.weight_arena % 256 != 0 or storage.device_scratch % 256 != 0)
            return error.InvalidStorage;
        const weight_end = @addWithOverflow(storage.weight_arena, @as(u64, @intCast(storage.weight_bytes)));
        const scratch_end = @addWithOverflow(storage.device_scratch, @as(u64, @intCast(storage.scratch_bytes)));
        if (weight_end[1] != 0 or scratch_end[1] != 0) return error.ArithmeticOverflow;
        if (storage.weight_arena < scratch_end[0] and storage.device_scratch < weight_end[0])
            return error.AliasedStorage;
        if (storage.mode == .expanded_f16) {
            if (storage.decoded_row.len == 0 or storage.input_half.len == 0)
                return error.Capacity;
            const spans = [_][]const u8{
                std.mem.sliceAsBytes(storage.entries),
                std.mem.sliceAsBytes(storage.decoded_row),
                std.mem.sliceAsBytes(storage.encoded_row),
                std.mem.sliceAsBytes(storage.upload_half),
                std.mem.sliceAsBytes(storage.input_half),
            };
            for (spans, 0..) |span, index| {
                for (spans[0..index]) |prior| if (overlap(span, prior)) return error.AliasedStorage;
            }
        } else if (overlap(std.mem.sliceAsBytes(storage.entries), std.mem.sliceAsBytes(storage.upload_half))) {
            return error.AliasedStorage;
        }
        return .{ .source = source, .storage = storage };
    }

    /// Callback directly assignable to executor.Progress.matrix_callback.
    /// Pin this Backend and its Source until execution and all GPU work finish.
    pub fn callback(context: *anyopaque, tensor: *const gguf.TensorInfo, input: []const f32, output: []f32, first_row: usize, end_row: usize) bool {
        const self: *Backend = @ptrCast(@alignCast(context));
        self.matvec(tensor, input, output, first_row, end_row) catch |err| {
            if (self.failure == null) self.failure = err;
            return false;
        };
        return true;
    }

    pub fn matvec(self: *Backend, tensor: *const gguf.TensorInfo, input: []const f32, output: []f32, first_row: usize, end_row: usize) Error!void {
        if (self.failure != null) return error.Failed;
        try self.checkCancelled();
        const shape = try matrixShape(tensor);
        if (input.len != shape.columns or output.len != shape.rows or
            first_row > end_row or end_row > shape.rows) return error.InvalidTensor;
        if (first_row == end_row) return;
        if (!cuda.isAvailable() or cuda.fn_cublasGemmEx == null or cuda.cublas_handle == null)
            return error.GpuUnavailable;
        for (input) |value| if (!std.math.isFinite(value)) return error.NonFinite;
        if (self.storage.mode == .expanded_f16) {
            if (input.len > self.storage.input_half.len) return error.Capacity;
            for (input, self.storage.input_half[0..input.len]) |value, *half| {
                half.* = @floatCast(value);
                if (!std.math.isFinite(half.*)) return error.NonFinite;
            }
        }
        const rows = end_row - first_row;
        const input_bytes = try mul(input.len, if (self.storage.mode == .quantized) @as(usize, 4) else 2);
        const output_offset = try align256(input_bytes);
        const output_bytes = try mul(rows, 4);
        if (output_offset > self.storage.scratch_bytes or output_bytes > self.storage.scratch_bytes - output_offset)
            return error.Capacity;
        const weight = try self.cachedMatrix(tensor);
        const input_device = self.storage.device_scratch;
        const output_device = input_device + output_offset;
        if (self.storage.mode == .quantized) {
            try self.packedMatvec(weight, tensor, input, output[first_row..end_row], first_row, input_device, output_device, shape);
            self.matrix_calls += 1;
            return;
        }
        if (!cuda.uploadToGpu(input_device, self.storage.input_half.ptr, input.len * 2)) return error.GpuFailure;
        const one: f32 = 1;
        const zero: f32 = 0;
        // Row-major W[rows,columns] is a column-major[columns,rows] operand.
        // Transposing it yields the requested output row slice, without packing.
        const status = cuda.fn_cublasGemmEx.?(cuda.cublas_handle.?, .T, .N, @intCast(rows), 1, @intCast(shape.columns), &one, @ptrFromInt(weight + first_row * shape.columns * 2), 2, @intCast(shape.columns), @ptrFromInt(input_device), 2, @intCast(shape.columns), &zero, @ptrFromInt(output_device), 0, @intCast(rows), 68, -1);
        if (status != 0 or !cuda.syncActiveStream()) return error.GpuFailure;
        if (!cuda.downloadFromGpu(output[first_row..end_row].ptr, output_device, output_bytes)) return error.GpuFailure;
        for (output[first_row..end_row]) |value| if (!std.math.isFinite(value)) return error.NonFinite;
        self.matrix_calls += 1;
    }

    pub fn preload(self: *Backend, tensors: []const gguf.TensorInfo) Error!void {
        if (self.failure != null) return error.Failed;
        for (tensors) |*tensor| {
            if (tensor.dimension_count != 2) continue;
            _ = try self.cachedMatrix(tensor);
        }
    }

    /// Invalidate cache metadata when switching model or reusing its arena.
    /// The caller owns synchronization and GPU memory; this does not free it.
    pub fn reset(self: *Backend, source: gguf.Source) void {
        self.source = source;
        self.entry_count = 0;
        self.arena_used = 0;
        self.failure = null;
        self.matrix_calls = 0;
        self.matrices_uploaded = 0;
        self.bytes_uploaded = 0;
    }

    pub fn deinit(self: *Backend) void {
        if (self.kernel_module) |module| cuda.unloadModule(module);
        self.kernel_module = null;
        self.packed_kernel = null;
    }

    fn packedMatvec(self: *Backend, weight: u64, tensor: *const gguf.TensorInfo, input: []const f32, output: []f32, first_row: usize, input_device: u64, output_device: u64, shape: Shape) Error!void {
        if (self.packed_kernel == null) {
            const module = cuda.loadModule(ptx.source.ptr) orelse return error.GpuFailure;
            errdefer cuda.unloadModule(module);
            const function = cuda.getFunction(module, "text_packed_matvec") orelse return error.GpuFailure;
            self.kernel_module = module;
            self.packed_kernel = function;
        }
        if (!cuda.uploadToGpu(input_device, input.ptr, input.len * 4)) return error.GpuFailure;
        var weights_arg = weight + first_row * shape.row_bytes;
        var input_arg = input_device;
        var output_arg = output_device;
        var columns_arg: u32 = @intCast(shape.columns);
        var rows_arg: u32 = @intCast(output.len);
        var row_bytes_arg: u32 = @intCast(shape.row_bytes);
        var type_arg = tensor.ggml_type;
        var warp_rows_arg: u32 = @intFromBool(self.storage.warp_rows);
        var args = [_]?*anyopaque{ &weights_arg, &input_arg, &output_arg, &columns_arg, &rows_arg, &row_bytes_arg, &type_arg, &warp_rows_arg };
        const blocks = if (self.storage.warp_rows) (rows_arg + 7) / 8 else rows_arg;
        if (!cuda.launchKernel(self.packed_kernel.?, blocks, 256, 0, &args) or !cuda.syncActiveStream()) return error.GpuFailure;
        if (!cuda.downloadFromGpu(output.ptr, output_device, output.len * 4)) return error.GpuFailure;
        for (output) |value| if (!std.math.isFinite(value)) return error.NonFinite;
    }

    fn checkCancelled(self: *const Backend) Error!void {
        if (self.is_cancelled) |cancel_fn| {
            const context = self.cancel_context orelse return error.Cancelled;
            if (cancel_fn(context)) return error.Cancelled;
        }
    }

    fn cachedMatrix(self: *Backend, tensor: *const gguf.TensorInfo) Error!u64 {
        const shape = try matrixShape(tensor);
        for (self.storage.entries[0..self.entry_count]) |entry| {
            if (entry.file_offset == tensor.file_offset and entry.encoded_bytes == tensor.byte_size and
                entry.ggml_type == tensor.ggml_type and entry.columns == shape.columns and entry.rows == shape.rows)
                return entry.device;
        }
        try self.checkCancelled();
        if (self.entry_count == self.storage.entries.len) return error.Capacity;
        if (self.storage.mode == .expanded_f16 and (shape.columns > self.storage.decoded_row.len or
            shape.columns > self.storage.upload_half.len)) return error.Capacity;
        const start = try align256(self.arena_used);
        const bytes = if (self.storage.mode == .quantized) std.math.cast(usize, tensor.byte_size) orelse return error.ArithmeticOverflow else try mul(try mul(shape.columns, shape.rows), 2);
        if (start > self.storage.weight_bytes or bytes > self.storage.weight_bytes - start) return error.Capacity;
        const destination = self.storage.weight_arena + start;
        if (self.storage.mode == .quantized) {
            const staging = std.mem.sliceAsBytes(self.storage.upload_half);
            if (staging.len == 0) return error.Capacity;
            var at: usize = 0;
            while (at < bytes) {
                try self.checkCancelled();
                const length = @min(staging.len, bytes - at);
                const offset = try add(tensor.file_offset, at);
                const data = self.source.view(offset, length, 1) orelse block: {
                    if (!self.source.read(offset, staging[0..length])) return error.StorageFailure;
                    break :block staging[0..length];
                };
                if (!cuda.uploadToGpu(destination + at, data.ptr, length)) return error.GpuFailure;
                self.bytes_uploaded += length;
                at += length;
            }
            self.commit(tensor, shape, destination, start + bytes);
            return destination;
        }
        const batch_rows = self.storage.upload_half.len / shape.columns;
        var row: usize = 0;
        while (row < shape.rows) {
            try self.checkCancelled();
            const count = @min(batch_rows, shape.rows - row);
            for (0..count) |in_batch| {
                const row_index = row + in_batch;
                const offset = try add(tensor.file_offset, try mul(row_index, shape.row_bytes));
                const data = self.source.view(offset, shape.row_bytes, 1) orelse block: {
                    if (shape.row_bytes > self.storage.encoded_row.len) return error.Capacity;
                    const buffer = self.storage.encoded_row[0..shape.row_bytes];
                    if (!self.source.read(offset, buffer)) return error.StorageFailure;
                    break :block buffer;
                };
                const decoded = self.storage.decoded_row[0..shape.columns];
                switch (tensor.ggml_type) {
                    0 => for (decoded, 0..) |*value, index| {
                        const b = data[index * 4 ..][0..4];
                        value.* = @bitCast(@as(u32, b[0]) | (@as(u32, b[1]) << 8) | (@as(u32, b[2]) << 16) | (@as(u32, b[3]) << 24));
                    },
                    12 => try quantized.dequantizeQ4K(decoded, data),
                    14 => try quantized.dequantizeQ6K(decoded, data),
                    else => return error.UnsupportedType,
                }
                const half = self.storage.upload_half[in_batch * shape.columns ..][0..shape.columns];
                for (decoded, half) |value, *target| {
                    if (!std.math.isFinite(value)) return error.NonFinite;
                    target.* = @floatCast(value);
                    if (!std.math.isFinite(target.*)) return error.NonFinite;
                }
            }
            const length = count * shape.columns * 2;
            if (!cuda.uploadToGpu(destination + row * shape.columns * 2, self.storage.upload_half.ptr, length)) return error.GpuFailure;
            self.bytes_uploaded += length;
            row += count;
        }
        self.commit(tensor, shape, destination, start + bytes);
        return destination;
    }

    fn commit(self: *Backend, tensor: *const gguf.TensorInfo, shape: Shape, destination: u64, end: usize) void {
        self.storage.entries[self.entry_count] = .{ .file_offset = tensor.file_offset, .encoded_bytes = tensor.byte_size, .ggml_type = tensor.ggml_type, .columns = shape.columns, .rows = shape.rows, .device = destination };
        self.entry_count += 1;
        self.arena_used = end;
        self.matrices_uploaded += 1;
    }
};

const Shape = struct { columns: usize, rows: usize, row_bytes: usize };
fn matrixShape(tensor: *const gguf.TensorInfo) Error!Shape {
    if (tensor.dimension_count != 2 or tensor.dimensions[0] == 0 or tensor.dimensions[1] == 0 or
        tensor.dimensions[0] > std.math.maxInt(c_int) or tensor.dimensions[1] > std.math.maxInt(c_int) or
        tensor.byte_size % tensor.dimensions[1] != 0) return error.InvalidTensor;
    const columns: usize = @intCast(tensor.dimensions[0]);
    const rows: usize = @intCast(tensor.dimensions[1]);
    const row_bytes: usize = @intCast(tensor.byte_size / tensor.dimensions[1]);
    const expected = switch (tensor.ggml_type) {
        0 => try mul(columns, 4),
        12 => try mul(columns / 256, 144),
        14 => try mul(columns / 256, 210),
        else => return error.UnsupportedType,
    };
    if (expected != row_bytes or row_bytes > std.math.maxInt(u32) or (tensor.ggml_type != 0 and columns % 256 != 0)) return error.InvalidTensor;
    return .{ .columns = columns, .rows = rows, .row_bytes = row_bytes };
}
pub fn requiredWeightBytes(tensors: []const gguf.TensorInfo) Error!usize {
    return requiredWeightBytesForMode(tensors, .quantized);
}
pub fn requiredWeightBytesForMode(tensors: []const gguf.TensorInfo, mode: Mode) Error!usize {
    var count: usize = 0;
    for (tensors) |*tensor| {
        if (tensor.dimension_count != 2) continue;
        const shape = try matrixShape(tensor);
        count = try align256(count);
        const bytes = if (mode == .quantized) std.math.cast(usize, tensor.byte_size) orelse return error.ArithmeticOverflow else try mul(try mul(shape.columns, shape.rows), 2);
        count = std.math.add(usize, count, bytes) catch return error.ArithmeticOverflow;
    }
    return count;
}
fn mul(a: usize, b: usize) Error!usize {
    const result = @mulWithOverflow(a, b);
    if (result[1] != 0) return error.ArithmeticOverflow;
    return result[0];
}
fn add(a: u64, b: usize) Error!u64 {
    const result = @addWithOverflow(a, @as(u64, @intCast(b)));
    if (result[1] != 0) return error.ArithmeticOverflow;
    return result[0];
}
fn align256(value: usize) Error!usize {
    if (value > std.math.maxInt(usize) - 255) return error.ArithmeticOverflow;
    return (value + 255) & ~@as(usize, 255);
}
fn overlap(a: []const u8, b: []const u8) bool {
    if (a.len == 0 or b.len == 0) return false;
    const a_start = @intFromPtr(a.ptr);
    const b_start = @intFromPtr(b.ptr);
    return if (a_start <= b_start) b_start - a_start < a.len else a_start - b_start < b.len;
}

test "native matrix backend rejects overlapping or overflowing caller arenas without CUDA" {
    const Probe = struct {
        fn read(_: *const anyopaque, _: u64, _: []u8) bool {
            return false;
        }
    };
    var entries: [2]CacheEntry = undefined;
    var upload: [16]f16 = undefined;
    const source: gguf.Source = .{ .context = &entries, .size = 0, .read_at = Probe.read };
    var storage: Storage = .{
        .weight_arena = 0x1000,
        .weight_bytes = 0x1000,
        .device_scratch = 0x3000,
        .scratch_bytes = 0x1000,
        .entries = &entries,
        .upload_half = &upload,
    };
    // Packed kernels do not require any expanded-weight or F16-input buffers.
    _ = try Backend.init(source, storage);
    storage.device_scratch = 0x1f00;
    try std.testing.expectError(error.AliasedStorage, Backend.init(source, storage));
    storage.device_scratch = 0x3001;
    try std.testing.expectError(error.InvalidStorage, Backend.init(source, storage));
    storage.device_scratch = 0x3000;
    storage.weight_arena = std.math.maxInt(u64) - 255;
    try std.testing.expectError(error.ArithmeticOverflow, Backend.init(source, storage));
    storage.weight_arena = 0x1000;
    storage.mode = .expanded_f16;
    try std.testing.expectError(error.Capacity, Backend.init(source, storage));
    storage.mode = .quantized;
    storage.upload_half = @as([*]f16, @ptrCast(&entries))[0..16];
    try std.testing.expectError(error.AliasedStorage, Backend.init(source, storage));
}

test "native matrix callback records terminal failure and source bounds precede I O" {
    const Probe = struct {
        reads: usize = 0,
        fn read(context: *const anyopaque, _: u64, _: []u8) bool {
            const self: *@This() = @ptrCast(@alignCast(@constCast(context)));
            self.reads += 1;
            return false;
        }
    };
    var probe: Probe = .{};
    var entries: [2]CacheEntry = undefined;
    var upload: [16]f16 = undefined;
    const source: gguf.Source = .{ .context = &probe, .size = 0, .read_at = Probe.read };
    var backend = try Backend.init(source, .{
        .weight_arena = 0x1000,
        .weight_bytes = 0x1000,
        .device_scratch = 0x3000,
        .scratch_bytes = 0x1000,
        .entries = &entries,
        .upload_half = &upload,
    });
    const valid: gguf.TensorInfo = .{ .dimension_count = 2, .dimensions = .{ 2, 2, 0, 0 }, .ggml_type = 0, .byte_size = 16 };
    try std.testing.expectError(error.StorageFailure, backend.preload(&.{valid}));
    try std.testing.expectEqual(@as(usize, 0), probe.reads);
    try std.testing.expectEqual(@as(usize, 0), backend.entry_count);
    try std.testing.expectEqual(@as(usize, 0), backend.arena_used);
    var invalid = valid;
    invalid.byte_size = 15;
    var output: [2]f32 = @splat(-99);
    try std.testing.expect(!Backend.callback(&backend, &invalid, &.{ 1, 2 }, &output, 0, 2));
    try std.testing.expectEqual(error.InvalidTensor, backend.failure.?);
    try std.testing.expect(!Backend.callback(&backend, &valid, &.{ 1, 2 }, &output, 0, 2));
    try std.testing.expectEqual(error.InvalidTensor, backend.failure.?);
    try std.testing.expectEqualSlices(f32, &.{ -99, -99 }, &output);
}

test "native CUDA matrix backend computes bounded slices with F32 accumulation and resident cache" {
    if (!cuda.init()) return error.SkipZigTest;
    defer cuda.deinit();
    const weights = [_]f32{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12 };
    const Source = struct {
        fn read(context: *const anyopaque, offset: u64, out: []u8) bool {
            const data: *const [12]f32 = @ptrCast(@alignCast(context));
            const bytes = std.mem.asBytes(data);
            if (offset > bytes.len or out.len > bytes.len - offset) return false;
            @memcpy(out, bytes[@intCast(offset)..][0..out.len]);
            return true;
        }
    };
    const source: gguf.Source = .{ .context = &weights, .size = 48, .read_at = Source.read };
    const arena = cuda.gpuAlloc(1024);
    if (arena == 0) return error.GpuFailure;
    defer cuda.gpuFree(arena);
    const scratch = cuda.gpuAlloc(1024);
    if (scratch == 0) return error.GpuFailure;
    defer cuda.gpuFree(scratch);
    var entries: [2]CacheEntry = undefined;
    var decoded: [4]f32 = undefined;
    var encoded: [16]u8 = undefined;
    var upload: [8]f16 = undefined;
    var input_half: [4]f16 = undefined;
    const tensor: gguf.TensorInfo = .{ .dimension_count = 2, .dimensions = .{ 4, 3, 0, 0 }, .ggml_type = 0, .byte_size = 48 };
    for ([_]Mode{ .expanded_f16, .quantized }) |mode| {
        var backend = try Backend.init(source, .{ .weight_arena = arena, .weight_bytes = 1024, .device_scratch = scratch, .scratch_bytes = 1024, .entries = &entries, .decoded_row = if (mode == .expanded_f16) &decoded else &.{}, .encoded_row = if (mode == .expanded_f16) &encoded else &.{}, .upload_half = &upload, .input_half = if (mode == .expanded_f16) &input_half else &.{}, .mode = mode });
        defer backend.deinit();
        var output: [3]f32 = @splat(-99);
        try backend.matvec(&tensor, &.{ 1, -2, 3, -4 }, &output, 1, 3);
        try std.testing.expectEqual(@as(f32, -99), output[0]);
        try std.testing.expectEqual(@as(f32, -18), output[1]);
        try std.testing.expectEqual(@as(f32, -26), output[2]);
        try backend.matvec(&tensor, &.{ 1, -2, 3, -4 }, &output, 0, 1);
        try std.testing.expectEqual(@as(f32, -10), output[0]);
        try std.testing.expectEqual(@as(u64, 1), backend.matrices_uploaded);
        try std.testing.expectEqual(@as(u64, 2), backend.matrix_calls);
        try std.testing.expectEqual(@as(usize, if (mode == .quantized) 48 else 24), backend.arena_used);
    }
}

test "packed native Q4 K and Q6 K cover every scale highbit and odd selected row" {
    if (!cuda.init()) return error.SkipZigTest;
    defer cuda.deinit();
    const ByteSource = struct {
        bytes: []const u8,
        fn read(context: *const anyopaque, offset: u64, out: []u8) bool {
            const self: *const @This() = @ptrCast(@alignCast(context));
            if (offset > self.bytes.len or out.len > self.bytes.len - offset) return false;
            @memcpy(out, self.bytes[@intCast(offset)..][0..out.len]);
            return true;
        }
    };
    var weights: [5 * 3 * 210]u8 = undefined;
    var input: [768]f32 = undefined;
    for (&input, 0..) |*value, i| value.* = @sin(@as(f32, @floatFromInt(i)) * 0.173) * 0.125;
    var seed: u32 = 0x192df4b7;
    const arena = cuda.gpuAlloc(8192);
    if (arena == 0) return error.GpuFailure;
    defer cuda.gpuFree(arena);
    const scratch = cuda.gpuAlloc(8192);
    if (scratch == 0) return error.GpuFailure;
    defer cuda.gpuFree(scratch);
    var entries: [2]CacheEntry = undefined;
    var decoded: [768]f32 = undefined;
    var encoded: [630]u8 = undefined;
    var upload: [1024]f16 = undefined;
    var input_half: [768]f16 = undefined;
    for ([_]bool{ false, true }) |warp_rows| for ([_]u32{ 12, 14 }) |ggml_type| {
        const block_size: usize = if (ggml_type == 12) 144 else 210;
        const row_bytes = block_size * 3;
        for (weights[0 .. row_bytes * 5]) |*byte| {
            seed = seed *% 1664525 +% 1013904223;
            byte.* = @truncate(seed >> 16);
        }
        for (0..15) |block| {
            const at = block * block_size;
            if (ggml_type == 12) {
                weights[at] = 0;
                weights[at + 1] = 0x38;
                weights[at + 2] = 0;
                weights[at + 3] = 0x30;
            } else {
                weights[at + 208] = 0;
                weights[at + 209] = 0x38;
            }
        }
        var source: ByteSource = .{ .bytes = weights[0 .. row_bytes * 5] };
        var backend = try Backend.init(.{ .context = &source, .size = source.bytes.len, .read_at = ByteSource.read }, .{ .weight_arena = arena, .weight_bytes = 8192, .device_scratch = scratch, .scratch_bytes = 8192, .entries = &entries, .decoded_row = &decoded, .encoded_row = &encoded, .upload_half = &upload, .input_half = &input_half, .mode = .quantized, .warp_rows = warp_rows });
        defer backend.deinit();
        const matrix: gguf.TensorInfo = .{ .dimension_count = 2, .dimensions = .{ 768, 5, 0, 0 }, .ggml_type = ggml_type, .byte_size = row_bytes * 5 };
        var output: [5]f32 = @splat(-999);
        try backend.matvec(&matrix, &input, &output, 1, 4);
        try std.testing.expectEqual(@as(f32, -999), output[0]);
        try std.testing.expectEqual(@as(f32, -999), output[4]);
        for (1..4) |row| {
            const data = weights[row * row_bytes ..][0..row_bytes];
            if (ggml_type == 12) try quantized.dequantizeQ4K(&decoded, data) else try quantized.dequantizeQ6K(&decoded, data);
            var expected: f64 = 0;
            for (decoded, input) |weight, value| expected += @as(f64, weight) * value;
            try std.testing.expectApproxEqAbs(@as(f32, @floatCast(expected)), output[row], @as(f32, 0.002));
        }
    };
}
