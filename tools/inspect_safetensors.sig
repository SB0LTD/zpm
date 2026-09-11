//! Validate a real memory-mapped model with the package's native tensor reader.
//! Output includes a digest of first/middle/last f32 values of every tensor,
//! allowing an independent reader to check dtype, offsets and conversion.
const std = @import("std");
const process = @import("sig_process");
const safe = @import("safetensors");
const sha256 = @import("sha256");
var infos: [2048]safe.TensorInfo = undefined;
var sample_bytes: [2048 * 3 * 4]u8 = undefined;

pub fn main(init: std.process.Init) !void {
    var argv_buffer: [32768]u8 = undefined;
    var argv = process.Argv_Iterator.init(init.minimal.args.vector, &argv_buffer);
    _ = try argv.next();
    const path = try argv.next() orelse return error.ExpectedModelPath;
    // skip never overwrites the iterator's path buffer.
    if (argv.skip()) return error.UnexpectedArgument;
    const file = try std.Io.Dir.cwd().openFile(init.io, path, .{});
    defer file.close(init.io);
    const size = try file.length(init.io);
    if (size > ~@as(usize, 0)) return error.ModelTooLarge;
    var mapping = try file.createMemoryMap(init.io, .{
        .len = @intCast(size),
        .protection = .{ .read = true, .write = false },
        // Sig 0.5.5's Windows section creation requires populate=true.
        .populate = true,
    });
    defer mapping.destroy(init.io);
    if (mapping.section == null) return error.NativeMappingRequired;
    const index = try safe.Index.parse(mapping.memory, &infos);
    var count: usize = 0;
    for (index.tensors) |info| {
        if (info.size == 0) continue;
        const view = index.view(info.name).?;
        for ([_]usize{ 0, info.size / 2, info.size - 1 }) |position| {
            const value: u32 = @bitCast(try view.floatAt(position));
            for (0..4) |byte| sample_bytes[count * 4 + byte] = @truncate(value >> @intCast(byte * 8));
            count += 1;
        }
    }
    const digest = sha256.hash(sample_bytes[0 .. count * 4]);
    var hex: [64]u8 = undefined;
    const alphabet = "0123456789abcdef";
    for (digest, 0..) |byte, i| {
        hex[i * 2] = alphabet[byte >> 4];
        hex[i * 2 + 1] = alphabet[byte & 15];
    }
    var output: [256]u8 = undefined;
    const line = try std.fmt.bufPrint(&output, "{{\"file_bytes\":{d},\"tensors\":{d},\"samples\":{d},\"sample_sha256\":\"{s}\"}}\n", .{ size, index.tensors.len, count, hex });
    try std.Io.File.stdout().writeStreamingAll(init.io, line);
}
