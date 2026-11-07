//! Development-only local tensor parity executable. Usage:
//! whisper-encoder-parity <ivrit-ggml-model> <Whisper-TensorOracle output dir>
//! The oracle is never loaded by production inference.
const std = @import("std");
const model = @import("whisper/model.sig");
const enc = @import("whisper/encoder.sig");
const kernels = @import("whisper/kernels.sig");
const Handle = *anyopaque;
extern "kernel32" fn GetCommandLineA() callconv(.winapi) [*:0]const u8;
extern "kernel32" fn CreateFileA([*:0]const u8, u32, u32, ?*anyopaque, u32, u32, ?Handle) callconv(.winapi) Handle;
extern "kernel32" fn GetFileSizeEx(Handle, *i64) callconv(.winapi) i32;
extern "kernel32" fn CreateFileMappingW(Handle, ?*anyopaque, u32, u32, u32, ?[*:0]const u16) callconv(.winapi) ?Handle;
extern "kernel32" fn MapViewOfFile(Handle, u32, u32, u32, usize) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn UnmapViewOfFile(*const anyopaque) callconv(.winapi) i32;
extern "kernel32" fn CloseHandle(Handle) callconv(.winapi) i32;
extern "kernel32" fn WriteFile(Handle, [*]const u8, u32, *u32, ?*anyopaque) callconv(.winapi) i32;

var tensors: [1024]model.Tensor = undefined;
var vocabulary: [52000]model.Token = undefined;
var encoder_storage: [26 * 1024 * 1024]f32 = undefined;
var kernel_storage: [4 * 1024 * 1024]f32 = undefined;
var entries: [1024]kernels.CacheEntry = undefined;

pub const Mapping = struct {
    file: Handle, mapping: Handle, bytes: []const u8,
    pub fn open(path: []const u8) !Mapping {
        var name: [4096]u8 = undefined;
        _ = try std.fmt.bufPrint(&name, "{s}\x00", .{path});
        const file = CreateFileA(@ptrCast(&name), 0x80000000, 1, null, 3, 0x80, null);
        if (@intFromPtr(file) == std.math.maxInt(usize)) return error.OpenFailed;
        errdefer _ = CloseHandle(file);
        var size: i64 = 0;
        if (GetFileSizeEx(file, &size) == 0 or size <= 0) return error.SizeFailed;
        const mapping = CreateFileMappingW(file, null, 2, 0, 0, null) orelse return error.MappingFailed;
        errdefer _ = CloseHandle(mapping);
        const address = MapViewOfFile(mapping, 4, 0, 0, 0) orelse return error.MappingFailed;
        return .{ .file = file, .mapping = mapping, .bytes = @as([*]const u8, @ptrCast(address))[0..@intCast(size)] };
    }
    pub fn floats(self: Mapping) []const f32 { return @as([*]const f32, @ptrCast(@alignCast(self.bytes.ptr)))[0 .. self.bytes.len / 4]; }
    pub fn close(self: Mapping) void { _ = UnmapViewOfFile(self.bytes.ptr); _ = CloseHandle(self.mapping); _ = CloseHandle(self.file); }
};

const Checker = struct {
    directory: []const u8,
    failed: bool = false,
    fn observe(context: ?*anyopaque, stage: enc.Stage, layer: usize, data: []const f32, rows: usize, cols: usize) void {
        const self: *Checker = @ptrCast(@alignCast(context.?));
        const leaf: []const u8 = switch (stage) {
            .conv1 => "oracle_conv1.f32", .conv2 => "embd_conv.f32",
            .layer => if (layer == 0) "oracle_encoder_layer_0.f32" else if (layer == 31) "oracle_encoder_layer_31.f32" else return,
            .final => "encoder_final.f32",
        };
        var path: [4096]u8 = undefined;
        const formatted = std.fmt.bufPrint(&path, "{s}/{s}", .{ self.directory, leaf }) catch { self.failed = true; return; };
        const mapped = Mapping.open(formatted) catch |err| { std.debug.print("FAIL oracle {s}: {s}\n", .{ leaf, @errorName(err) }); self.failed = true; return; };
        defer mapped.close();
        const oracle = mapped.floats();
        if (oracle.len != data.len) { self.failed = true; return; }
        var absolute: f64 = 0;
        var square: f64 = 0;
        var magnitude: f64 = 0;
        var largest: f32 = 0;
        for (0..rows) |r| for (0..cols) |c| {
            const expected = oracle[if (stage == .conv1 or stage == .conv2) c * rows + r else r * cols + c];
            const actual = data[r * cols + c];
            const difference = @abs(actual - expected);
            if (!std.math.isFinite(actual)) self.failed = true;
            absolute += difference; square += @as(f64, difference) * difference;
            magnitude += @as(f64, expected) * expected;
            largest = @max(largest, difference);
        };
        std.debug.print("{s}: MAE={d:.7} RMSE={d:.7} relative_RMSE={d:.7} max={d:.7}\n", .{ leaf, absolute / @as(f64, @floatFromInt(data.len)), @sqrt(square / @as(f64, @floatFromInt(data.len))), @sqrt(square / @max(magnitude, 1e-20)), largest });
        // Independent CUDA kernels may select different half-precision GEMM
        // reductions. Use stage-specific guards and check decoded tokens too.
        const bound: f64 = switch (stage) { .conv1 => 0.0001, .conv2 => 0.005, .layer => if (layer == 0) 0.005 else 0.03, .final => 0.05 };
        if (@sqrt(square / @max(magnitude, 1e-20)) > bound) self.failed = true;
    }
};

pub fn main() !void {
    var args = std.mem.tokenizeScalar(u8, std.mem.span(GetCommandLineA()), ' ');
    _ = args.next();
    const model_path = args.next() orelse return error.Usage;
    const oracle_dir = args.next() orelse return error.Usage;
    if (args.next() != null) return error.Usage;
    const model_map = try Mapping.open(model_path); defer model_map.close();
    const parsed = try model.parse(model_map.bytes, &tensors, &vocabulary);
    var encoder = try enc.Encoder.init(&parsed);
    var checker: Checker = .{ .directory = oracle_dir };
    encoder.observer = .{ .context = &checker, .observe = Checker.observe };
    var workspace = try enc.Workspace.init(&encoder_storage, parsed.hparams);
    var mel_path: [4096]u8 = undefined;
    const mel_map = try Mapping.open(try std.fmt.bufPrint(&mel_path, "{s}/mel.f32", .{oracle_dir})); defer mel_map.close();
    if (!kernels.cuda.init()) return error.CudaUnavailable;
    defer kernels.cuda.deinit();
    const arena = kernels.cuda.gpuAlloc(2 * 1024 * 1024 * 1024);
    if (arena == 0) return error.GpuFailure;
    defer kernels.cuda.gpuFree(arena);
    const scratch = kernels.cuda.gpuAlloc(64 * 1024 * 1024);
    if (scratch == 0) return error.GpuFailure;
    defer kernels.cuda.gpuFree(scratch);
    var gpu = try kernels.Gpu.init(arena, 2 * 1024 * 1024 * 1024, &entries, scratch, 64 * 1024 * 1024);
    defer gpu.deinit();
    var engine: kernels.Engine = .{ .scratch = &kernel_storage, .gpu = &gpu };
    const encoded = try encoder.encode(mel_map.floats(), &workspace, &engine);
    var output_name: [4096]u8 = undefined;
    _ = try std.fmt.bufPrint(&output_name, "{s}/native_encoder.f32\x00", .{oracle_dir});
    const file = CreateFileA(@ptrCast(&output_name), 0x40000000, 1, null, 2, 0x80, null);
    if (@intFromPtr(file) == std.math.maxInt(usize)) return error.OpenFailed;
    defer _ = CloseHandle(file);
    var written: u32 = 0;
    const bytes = std.mem.sliceAsBytes(encoded);
    if (WriteFile(file, bytes.ptr, @intCast(bytes.len), &written, null) == 0 or written != bytes.len) return error.WriteFailed;
    if (checker.failed) return error.NumericalMismatch;
    std.debug.print("PASS encoder tensor comparison; cached tensors={d}, bytes={d}\n", .{ gpu.entry_count, gpu.used });
}
