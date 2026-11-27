const z = @import("zpm_slowwire");
const io = z.windows;
var firmware: [2 * 1024 * 1024]u8 = undefined;
pub fn main() !void {
    const args = try io.Args.load();
    if (args.count != 4) {
        io.print("usage: slowwire-uf2 boot2.bin firmware.bin output.uf2\n");
        return error.Args;
    }
    @memset(firmware[0..256], 0);
    const boot = try io.open(args.get(1), false);
    const n = try io.read(boot, firmware[0..253]);
    io.close(boot);
    if (n == 0 or n > 252) return error.BootSize;
    z.dynamixel2.put32(firmware[252..256], z.uf2.bootCrc(firmware[0..252]));
    const app = try io.open(args.get(2), false);
    defer io.close(app);
    var length: usize = 256;
    while (length < firmware.len) {
        const got = try io.read(app, firmware[length..]);
        if (got == 0) break;
        length += got;
    }
    if (length == firmware.len or length < 320) return error.ImageSize;
    // Vector table: SRAM stack and odd Thumb reset handler in flash.
    const sp = z.dynamixel2.get32(firmware[256..260]);
    const pc = z.dynamixel2.get32(firmware[260..264]);
    if (sp < 0x20000000 or sp > 0x20040000 or pc & 1 != 1 or pc < 0x10000101 or pc >= 0x10000000 + length) return error.Vectors;
    const out = try io.open(args.get(3), true);
    defer io.close(out);
    const total: u32 = @intCast((length + 255) / 256);
    var b: [512]u8 = undefined;
    for (0..total) |i| {
        const offset = i * 256;
        try z.uf2.block(&b, firmware[offset..@min(offset + 256, length)], @intCast(i), total);
        try io.write(out, &b);
    }
    io.print("UF2 blocks=");
    io.number(total);
    io.print(" bytes=");
    io.number(@intCast(length));
    io.print(" (physical boot unverified)\n");
}
