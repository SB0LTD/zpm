//! Explicit real-model CPU/native-CUDA logits parity and warm-speed probe.
const std = @import("std");
const gguf = @import("gguf");
const plan_module = @import("qwen3_decoder_plan");
const executor = @import("qwen3_executor");
const gpu_module = @import("llm/text_gpu.sig");
const arguments = @import("core/windows_arguments.sig");
const cuda = gpu_module.cuda;
const Handle = *anyopaque;
extern "kernel32" fn CreateFileW([*:0]const u16, u32, u32, ?*anyopaque, u32, u32, ?Handle) callconv(.winapi) Handle;
extern "kernel32" fn GetFileSizeEx(Handle, *i64) callconv(.winapi) i32;
extern "kernel32" fn CreateFileMappingW(Handle, ?*anyopaque, u32, u32, u32, ?[*:0]const u16) callconv(.winapi) ?Handle;
extern "kernel32" fn MapViewOfFile(Handle, u32, u32, u32, usize) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn UnmapViewOfFile(*const anyopaque) callconv(.winapi) i32;
extern "kernel32" fn CloseHandle(Handle) callconv(.winapi) i32;
extern "kernel32" fn GetCommandLineW() callconv(.winapi) [*:0]const u16;
extern "kernel32" fn QueryPerformanceCounter(*i64) callconv(.winapi) i32;
extern "kernel32" fn QueryPerformanceFrequency(*i64) callconv(.winapi) i32;
var frequency: i64 = 0;
fn clockTicks() i64 {
    var value: i64 = 0;
    _ = QueryPerformanceCounter(&value);
    return value;
}
fn elapsedMs(start: i64) f64 {
    return @as(f64, @floatFromInt(clockTicks() - start)) * 1000 / @as(f64, @floatFromInt(frequency));
}
const limits = executor.Limits{ .hidden = 2560, .query = 4096, .key_value = 1024, .feed_forward = 9728, .vocabulary = 151936, .context = 8, .row_bytes = 38912 };
var cpu_work: executor.WorkingSet(limits) = .{};
var gpu_work: executor.WorkingSet(limits) = .{};
var cpu_kv: [36 * limits.context * limits.key_value * 2]u16 = undefined;
var gpu_kv: [36 * limits.context * limits.key_value * 2]u16 = undefined;
var index: gguf.Index(1024) = .{};
var plan: plan_module.Plan = undefined;
var entries: [1024]gpu_module.CacheEntry = undefined;
var decoded: [32768]f32 = undefined;
var encoded: [131072]u8 = undefined;
var upload: [1048576]f16 = undefined;
var input_half: [32768]f16 = undefined;
const Source = struct {
    bytes: []const u8,
    fn read(context: *const anyopaque, offset: u64, out: []u8) bool {
        const self: *const Source = @ptrCast(@alignCast(context));
        if (offset > self.bytes.len or out.len > self.bytes.len - offset) return false;
        @memcpy(out, self.bytes[@intCast(offset)..][0..out.len]);
        return true;
    }
    fn map(context: *const anyopaque, offset: u64, length: usize, alignment: usize) ?[*]const u8 {
        const self: *const Source = @ptrCast(@alignCast(context));
        if (offset > self.bytes.len or length > self.bytes.len - offset) return null;
        const result = self.bytes[@intCast(offset)..].ptr;
        if (@intFromPtr(result) % alignment != 0) return null;
        return result;
    }
    fn source(self: *const Source) gguf.Source {
        return .{ .context = self, .size = self.bytes.len, .read_at = read, .map_at = map };
    }
};
fn check(path: []const u8, warp_rows: bool) !void {
    var wide_path: [32768]u16 = undefined;
    const wide_length = try std.unicode.utf8ToUtf16Le(wide_path[0 .. wide_path.len - 1], path);
    wide_path[wide_length] = 0;
    const input = CreateFileW(@ptrCast(&wide_path), 0x80000000, 1, null, 3, 0x80, null);
    if (@intFromPtr(input) == std.math.maxInt(usize)) return error.OpenFailed;
    defer _ = CloseHandle(input);
    var size: i64 = 0;
    if (GetFileSizeEx(input, &size) == 0 or size <= 0) return error.SizeFailed;
    const mapping = CreateFileMappingW(input, null, 2, 0, 0, null) orelse return error.MappingFailed;
    defer _ = CloseHandle(mapping);
    const address = MapViewOfFile(mapping, 4, 0, 0, 0) orelse return error.MappingFailed;
    defer _ = UnmapViewOfFile(address);
    var source: Source = .{ .bytes = @as([*]const u8, @ptrCast(address))[0..@intCast(size)] };
    try gguf.parse(1024, source.source(), &index);
    try plan_module.build(1024, &index, &plan);
    const required = try gpu_module.requiredWeightBytesForMode(index.tensors[0..index.tensor_count], .quantized);
    const arena = cuda.gpuAlloc(required);
    if (arena == 0) return error.GpuCapacity;
    defer cuda.gpuFree(arena);
    const scratch = cuda.gpuAlloc(1024 * 1024);
    if (scratch == 0) return error.GpuCapacity;
    defer cuda.gpuFree(scratch);
    var backend = try gpu_module.Backend.init(source.source(), .{ .weight_arena = arena, .weight_bytes = required, .device_scratch = scratch, .scratch_bytes = 1024 * 1024, .entries = &entries, .decoded_row = &decoded, .encoded_row = &encoded, .upload_half = &upload, .input_half = &input_half, .mode = .quantized, .warp_rows = warp_rows });
    defer backend.deinit();
    var tick = clockTicks();
    try backend.preload(index.tensors[0..index.tensor_count]);
    const preload_ms = elapsedMs(tick);
    const tokens = [_]u32{ 151644, 872, 198, 9707, 1879, 0, 151645, 198 };
    const progress: executor.Progress = .{ .matrix_context = &backend, .matrix_callback = &gpu_module.Backend.callback };
    cpu_work = .{};
    gpu_work = .{};
    for (tokens, 0..) |token, position| {
        tick = clockTicks();
        const cpu_selected = try executor.forward(1024, limits, source.source(), &index, &plan, &cpu_work, &cpu_kv, limits.context, token, position, true, .{});
        const cpu_ms = elapsedMs(tick);
        tick = clockTicks();
        const gpu_selected = executor.forward(1024, limits, source.source(), &index, &plan, &gpu_work, &gpu_kv, limits.context, token, position, true, progress) catch |err| {
            std.debug.print("GPU failure {s}; backend={any}\n", .{ @errorName(err), backend.failure });
            return err;
        };
        const gpu_ms = elapsedMs(tick);
        var maximum: f32 = 0;
        var squared: f64 = 0;
        var energy: f64 = 0;
        for (cpu_work.logits[0..plan.vocabulary_size], gpu_work.logits[0..plan.vocabulary_size]) |expected, actual| {
            const difference = actual - expected;
            maximum = @max(maximum, @abs(difference));
            squared += @as(f64, difference) * difference;
            energy += @as(f64, expected) * expected;
        }
        const rms = @sqrt(squared / @as(f64, @floatFromInt(plan.vocabulary_size)));
        std.debug.print("{s} warp_rows={any} position={d} cpu_token={any} gpu_token={any} maxabs={d:.7} rms={d:.7} cpu_ms={d:.3} gpu_ms={d:.3} preload_ms={d:.3} resident_bytes={d}\n", .{ path, warp_rows, position, cpu_selected, gpu_selected, maximum, rms, cpu_ms, gpu_ms, preload_ms, backend.arena_used });
        if (cpu_selected != gpu_selected or maximum > 0.15 or rms > 0.02 or squared > energy * 0.0001) return error.ParityFailure;
    }
    // Isolate warm execution from CPU-reference work and initial PTX loading.
    // Replaying the eight-token prefix overwrites its KV entries before use.
    const iterations = 32;
    var warm_minimum: f64 = std.math.inf(f64);
    var warm_total: f64 = 0;
    for (0..iterations) |iteration| {
        const position = iteration % tokens.len;
        tick = clockTicks();
        _ = try executor.forward(1024, limits, source.source(), &index, &plan, &gpu_work, &gpu_kv, limits.context, tokens[position], position, true, progress);
        const duration = elapsedMs(tick);
        warm_minimum = @min(warm_minimum, duration);
        warm_total += duration;
    }
    std.debug.print("WARM model={s} warp_rows={any} iterations={d} mean_ms={d:.3} minimum_ms={d:.3} resident_bytes={d}\n", .{
        path, warp_rows, iterations, warm_total / iterations, warm_minimum, backend.arena_used,
    });
}
pub fn main() !void {
    var command: [32768]u8 = undefined;
    var decoded_arguments: [32768]u8 = undefined;
    var spans: [18]arguments.Span = undefined;
    const command_length = try std.unicode.utf16LeToUtf8(&command, std.mem.span(GetCommandLineW()));
    const count = try arguments.parse(command[0..command_length], &decoded_arguments, &spans);
    var first_model: usize = 1;
    const warp_first = count > 1 and std.mem.eql(u8, decoded_arguments[spans[1].begin..spans[1].end], "--warp-first");
    if (warp_first) first_model += 1;
    if (first_model == count) {
        std.debug.print("Usage: text-gpu-parity [--warp-first] model.gguf [model.gguf ...]\n", .{});
        return error.MissingModel;
    }
    if (QueryPerformanceFrequency(&frequency) == 0 or frequency <= 0) return error.ClockFailed;
    if (!cuda.init()) return error.GpuUnavailable;
    defer cuda.deinit();
    for ([_]bool{ warp_first, !warp_first }) |warp_rows|
        for (spans[first_model..count]) |span|
            try check(decoded_arguments[span.begin..span.end], warp_rows);
}
