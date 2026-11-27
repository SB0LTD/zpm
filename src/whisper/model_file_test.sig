//! Explicit, local-model integration check (not a portable unit test).
//! Run as an executable on the Gotliv development machine. Reads both actual
//! ivrit-ai GGML files through read-only OS mappings without copying weights.
const std = @import("std");
const model = @import("model.sig");
const tokenizer = @import("tokenizer.sig");

const Handle = *anyopaque;
extern "kernel32" fn CreateFileW([*:0]const u16, u32, u32, ?*anyopaque, u32, u32, ?Handle) callconv(.winapi) Handle;
extern "kernel32" fn GetFileSizeEx(Handle, *i64) callconv(.winapi) i32;
extern "kernel32" fn CreateFileMappingW(Handle, ?*anyopaque, u32, u32, u32, ?[*:0]const u16) callconv(.winapi) ?Handle;
extern "kernel32" fn MapViewOfFile(Handle, u32, u32, u32, usize) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn UnmapViewOfFile(*const anyopaque) callconv(.winapi) i32;
extern "kernel32" fn CloseHandle(Handle) callconv(.winapi) i32;

var tensors: [model.DEFAULT_TENSOR_CAPACITY]model.Tensor = undefined;
var vocabulary: [model.DEFAULT_VOCABULARY_CAPACITY]model.Token = undefined;

fn check(comptime path: []const u8) !void {
    const wide = std.unicode.utf8ToUtf16LeStringLiteral(path);
    const file = CreateFileW(wide, 0x80000000, 1, null, 3, 0x80, null);
    if (@intFromPtr(file) == std.math.maxInt(usize)) return error.OpenFailed;
    defer _ = CloseHandle(file);
    var size: i64 = 0;
    if (GetFileSizeEx(file, &size) == 0 or size <= 0) return error.SizeFailed;
    const mapping = CreateFileMappingW(file, null, 2, 0, 0, null) orelse return error.MappingFailed;
    defer _ = CloseHandle(mapping);
    const address = MapViewOfFile(mapping, 4, 0, 0, 0) orelse return error.MappingFailed;
    defer _ = UnmapViewOfFile(address);
    const bytes: []const u8 = @as([*]const u8, @ptrCast(address))[0..@intCast(size)];
    const parsed = try model.parse(bytes, &tensors, &vocabulary);
    if (parsed.hparams.n_vocab != 51866 or parsed.hparams.n_audio_layer != 32 or
        parsed.hparams.n_text_layer != 4 or parsed.hparams.n_mels != 128 or
        parsed.tensors.len != 587 or parsed.vocabulary.len != 50257)
        return error.UnexpectedModel;
    const conv1 = parsed.find("encoder.conv1.weight") orelse return error.MissingTensor;
    if (conv1.encoding != .f16 or conv1.rank != 3 or conv1.dimensions[0] != 3 or
        conv1.dimensions[1] != 128 or conv1.dimensions[2] != 1280)
        return error.UnexpectedTensor;
    var output: [32]u8 = undefined;
    const length = try tokenizer.decode(&parsed, &.{ 50258, 50279, 50360, 7972, 5365, 50257 }, &output);
    if (!std.mem.eql(u8, output[0..length], "\xd7\x90\xd7\xa9")) return error.WrongDecodedText;
    const last = parsed.find("decoder.ln.bias") orelse return error.MissingTensor;
    std.debug.print("PASS {s}: {d} bytes, {d} tensors, {d} stored tokens, conv[0]={d:.7}, decoder_ln_bias[1279]={d:.7}\n", .{ path, bytes.len, parsed.tensors.len, parsed.vocabulary.len, conv1.value(0), last.value(1279) });
}

pub fn main() !void {
    try check("C:/Just-Things/Projects/gotliv/models/ggml-model.bin");
    try check("C:/Just-Things/Projects/gotliv/models/ggml-large-v3-turbo.bin");
}
