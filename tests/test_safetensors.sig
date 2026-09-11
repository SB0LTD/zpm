//! Executed contracts for real tensor metadata and adversarial file boundaries.
const std = @import("std");
const safe = @import("safetensors");
var assertions: usize = 0;
var file: [8192]u8 align(8) = undefined;
var infos: [32]safe.TensorInfo = undefined;
fn check(ok: bool) !void {
    assertions += 1;
    if (!ok) return error.SafetensorsContractFailed;
}
fn fixture(header: []const u8, data: []const u8) []u8 {
    for (0..8) |i| file[i] = @truncate(@as(u64, header.len) >> @intCast(i * 8));
    @memcpy(file[8..][0..header.len], header);
    @memcpy(file[8 + header.len ..][0..data.len], data);
    return file[0 .. 8 + header.len + data.len];
}
fn reject(header: []const u8, data: []const u8, expected: safe.Error) !void {
    if (safe.Index.parse(fixture(header, data), &infos)) |_| return error.InvalidFileAccepted else |err| try check(err == expected);
}
pub fn main(init: std.process.Init) !void {
    // These files are serialized and independently deserialized by the pinned
    // official implementation; the native reader must agree on layout/values.
    inline for (.{ "floats", "mixed-order" }) |name| {
        const reference = try safe.Index.parse(@embedFile("fixtures/safetensors/" ++ name ++ ".bin"), &infos);
        try check(try reference.view("bf16").?.floatAt(0) == 1.0);
        try check(try reference.view("bf16").?.floatAt(1) == -2.0);
        try check(try reference.view("f16").?.floatAt(0) == 0.5);
        try check(try reference.view("f16").?.floatAt(1) == -4.0);
        try check(try reference.view("f32").?.floatAt(0) == -0.25);
        try check(try reference.view("f32").?.floatAt(1) == 3.5);
    }
    const scalars = try safe.Index.parse(@embedFile("fixtures/safetensors/empty-scalar.bin"), &infos);
    try check(scalars.find("empty").?.size == 0);
    try check(scalars.find("scalar").?.n_dims == 0);
    try check(try scalars.view("scalar").?.floatAt(0) == 3.5);
    const integers = try safe.Index.parse(@embedFile("fixtures/safetensors/integers.bin"), &infos);
    try check(integers.tensors.len == 9);
    for (integers.tensors) |info| try check(info.size == 2 and info.byte_size == 2 * info.dtype.bytes());
    try check(integers.view("i8").?.data[0] == 0x80 and integers.view("i8").?.data[1] == 0x7f);
    if (integers.view("u64").?.floatAt(0)) |_| return error.IntegerReadAsFloat else |err| try check(err == error.WrongDtype);
    const header = "{\"b\":{\"data_offsets\":[4,8],\"shape\":[],\"dtype\":\"F32\"},\"a\":{\"dtype\":\"BF16\",\"shape\":[2],\"data_offsets\":[0,4]},\"empty\":{\"shape\":[0,9],\"dtype\":\"F16\",\"data_offsets\":[4,4]},\"__metadata__\":{\"format\":\"pt\",\"note\":\"שלום \\ud83c\\udf10\"}} ";
    const data = "\x80\x3f\x00\xc0\x00\x00\x60\x40";
    const encoded = fixture(header, data);
    const index = try safe.Index.parse(encoded, &infos);
    try check(index.tensors.len == 3);
    try check(index.find("missing") == null);
    const a = index.view("a").?;
    try check(a.info.n_dims == 1 and a.info.shape[0] == 2);
    try check(try a.floatAt(0) == 1.0);
    try check(try a.floatAt(1) == -2.0);
    try check(try index.view("b").?.floatAt(0) == 3.5);
    try check(index.find("empty").?.size == 0);
    if (a.floatAt(2)) |_| return error.BoundsNotEnforced else |err| try check(err == error.OutOfBounds);
    for (0..encoded.len) |len| {
        if (safe.Index.parse(encoded[0..len], &infos)) |_| return error.TruncationAccepted else |_| assertions += 1;
    }
    if (safe.Index.parse(encoded, infos[0..2])) |_| return error.CapacityNotEnforced else |err| try check(err == error.CapacityExceeded);
    // All address arithmetic is checked before pointer formation.
    const envelope = safe.SafetensorsFile.init(encoded.ptr, encoded.len).?;
    try check(envelope.tensorDataBf16(~@as(usize, 0), 0) == null);
    try check(envelope.tensorDataBf16(0, ~@as(usize, 0)) == null);
    try check(envelope.tensorDataBf16(data.len + 1, 0) == null);
    const unaligned_offset: usize = if ((@intFromPtr(encoded.ptr) + envelope.data_offset) % 2 == 0) 1 else 0;
    try check(envelope.tensorDataBf16(unaligned_offset, 1) == null);
    @memset(file[0..8], 0xff);
    try check(safe.SafetensorsFile.init(&file, file.len) == null);
    if (safe.Index.parse(file[0..8], &infos)) |_| return error.HeaderOverflowAccepted else |err| try check(err == error.HeaderTooLarge);
    const empty = try safe.Index.parse(fixture("{}", ""), &infos);
    try check(empty.tensors.len == 0);
    const half = try safe.Index.parse(fixture("{\"x\":{\"dtype\":\"F16\",\"shape\":[2],\"data_offsets\":[0,4]}}", "\x00\x3c\x00\xc0"), &infos);
    try check(try half.view("x").?.floatAt(0) == 1.0);
    try check(try half.view("x").?.floatAt(1) == -2.0);
    try reject("{}", "x", error.InvalidOffsets);
    try reject("{\"x\":{\"dtype\":\"BF16\",\"shape\":[1],\"data_offsets\":[1,3]}}", "\x00\x00\x00", error.InvalidOffsets);
    try reject("{\"a\":{\"dtype\":\"U8\",\"shape\":[1],\"data_offsets\":[0,1]},\"b\":{\"dtype\":\"U8\",\"shape\":[1],\"data_offsets\":[0,1]}}", "x", error.InvalidOffsets);
    try reject("{\"x\":{\"dtype\":\"BF16\",\"shape\":[2],\"data_offsets\":[0,2]}}", "xx", error.InvalidShape);
    try reject("{\"x\":{\"dtype\":\"BF16\",\"shape\":[1],\"data_offsets\":[2,0]}}", "", error.InvalidOffsets);
    try reject("{\"x\":{\"dtype\":\"BF16\",\"shape\":[18446744073709551615,2],\"data_offsets\":[0,0]}}", "", error.Overflow);
    try reject("{\"x\":{\"dtype\":\"U8\",\"shape\":[18446744073709551615,2,0],\"data_offsets\":[0,0]}}", "", error.Overflow);
    const zero_first = try safe.Index.parse(fixture("{\"x\":{\"dtype\":\"U8\",\"shape\":[0,18446744073709551615,2],\"data_offsets\":[0,0]}}", ""), &infos);
    try check(zero_first.find("x").?.size == 0);
    try reject("{\"x\":{\"dtype\":\"BF16\",\"shape\":[18446744073709551616],\"data_offsets\":[0,0]}}", "", error.Overflow);
    try reject("{\"x\":{\"dtype\":\"BF16\",\"shape\":[1,1,1,1,1,1,1,1,1],\"data_offsets\":[0,2]}}", "xx", error.InvalidShape);
    try reject("{\"x\":{\"dtype\":\"F4\",\"shape\":[1],\"data_offsets\":[0,1]}}", "x", error.UnsupportedDtype);
    try reject("{\"x\":{\"dtype\":\"U8\",\"dtype\":\"U8\",\"shape\":[1],\"data_offsets\":[0,1]}}", "x", error.DuplicateKey);
    try reject("{\"x\":{\"dtype\":\"U8\",\"shape\":[1],\"data_offsets\":[0,1]},\"x\":{\"dtype\":\"U8\",\"shape\":[1],\"data_offsets\":[1,2]}}", "xx", error.DuplicateKey);
    try reject("{\"__metadata__\":{},\"__metadata__\":{}}", "", error.DuplicateKey);
    try reject("{\"__metadata__\":{\"a\":\"x\",\"a\":\"y\"}}", "", error.DuplicateKey);
    try reject("{\"__metadata__\":{\"a\":false}}", "", error.InvalidJson);
    try reject("{\"__metadata__\":{\"a\":\"\\ud800\"}}", "", error.InvalidJson);
    try reject("{\"__metadata__\":{\"a\":\"\\udc00\"}}", "", error.InvalidJson);
    try reject("{\"__metadata__\":{\"a\":\"\\q\"}}", "", error.InvalidJson);
    try reject("{\"__metadata__\":{\"a\":\"\xff\"}}", "", error.InvalidUtf8);
    try reject("{\"\\u0078\":{}}", "", error.UnsupportedName);
    try reject("{\"x\":{\"dtype\":\"U8\",\"shape\":[01],\"data_offsets\":[0,1]}}", "x", error.InvalidJson);
    try reject("{\"x\":{\"dtype\":\"U8\",\"shape\":[-1],\"data_offsets\":[0,1]}}", "x", error.InvalidJson);
    try reject("{\"x\":{\"dtype\":\"U8\",\"shape\":[1],}}", "x", error.InvalidJson);
    try reject("{} trailing", "", error.InvalidJson);
    // Deterministic arbitrary-header mutations must return an error or a valid
    // in-bounds index under ReleaseSafe, never trap on arithmetic or indexing.
    const base_header = "{\"x\":{\"dtype\":\"BF16\",\"shape\":[1],\"data_offsets\":[0,2]}}";
    for (0..base_header.len) |position| for (0..256) |replacement| {
        const mutated = fixture(base_header, "\x80\x3f");
        mutated[8 + position] = @intCast(replacement);
        if (safe.Index.parse(mutated, &infos)) |accepted| {
            for (accepted.tensors) |info| try check(info.offset <= 2 and info.byte_size <= 2 - info.offset);
        } else |_| assertions += 1;
    };
    var message: [128]u8 = undefined;
    const line = try std.fmt.bufPrint(&message, "PASS safetensors: {d} executed assertions\n", .{assertions});
    try std.Io.File.stdout().writeStreamingAll(init.io, line);
}
