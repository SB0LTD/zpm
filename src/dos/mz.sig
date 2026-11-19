//! DOS's program loader: MZ executables (the header, the load image after
//! it, the relocations, the minimum and maximum extra memory, the entry
//! CS:IP and SS:SP) and COM files (the file at PSP:0100h). The kind comes
//! from the signature ("MZ" or "ZM"), not the name, as DOS decides.
//! Written from the MS-DOS programmer's reference's description of the
//! .EXE header.

const std = @import("std");
const Memory = @import("mem.sig").Memory;
const host_mod = @import("host.sig");
const Host = host_mod.Host;

pub const Err = error{ Format, Read };

/// The largest COM file (64 KiB less the PSP and a stack word).
pub const COM_MAX: u32 = 0xFF00;

pub const Image = struct {
    exe: bool = false,
    /// The load image's bytes and where they start in the file.
    size: u32 = 0,
    file_off: u32 = 0,
    /// Paragraphs: the image, and the extra memory it asks for.
    paras: u32 = 0,
    min_extra: u32 = 0,
    max_extra: u32 = 0,
    cs: u16 = 0,
    ip: u16 = 0x100,
    ss: u16 = 0,
    sp: u16 = 0xFFFE,
    relocs: u16 = 0,
    reloc_off: u32 = 0,

    /// Loaded at the top of memory (min and max extra both 0).
    pub fn high(self: *const Image) bool {
        return self.exe and self.min_extra == 0 and self.max_extra == 0;
    }
};

fn rd16(b: []const u8, at: usize) u16 {
    return std.mem.readInt(u16, b[at..][0..2], .little);
}

/// What an open file (`fd`, `file_size` bytes) is and how it loads.
pub fn inspect(host: Host, fd: i32, file_size: u64) Err!Image {
    var hdr: [0x1C]u8 = [_]u8{0} ** 0x1C;
    if (host.seek(fd, 0, .set) < 0) return error.Read;
    const got = host.read(fd, &hdr);
    if (got < 0) return error.Read;
    const n: usize = @intCast(got);
    const sig = if (n >= 2) rd16(&hdr, 0) else 0;
    if (n < 0x1C or (sig != 0x5A4D and sig != 0x4D5A)) {
        // A COM file.
        if (file_size > COM_MAX) return error.Format;
        const sz: u32 = @intCast(file_size);
        return .{ .exe = false, .size = sz, .file_off = 0, .paras = (sz + 15) / 16 };
    }
    const last = rd16(&hdr, 2) & 0x1FF;
    const pages = rd16(&hdr, 4);
    const hdr_paras = rd16(&hdr, 8);
    var total: u32 = @as(u32, pages) * 512;
    if (last != 0) total -= 512 - @as(u32, last);
    const hdr_bytes = @as(u32, hdr_paras) * 16;
    if (pages == 0 or total < hdr_bytes) return error.Format;
    // A header that claims more than the file has: load what is there.
    const in_file: u32 = @intCast(@min(@as(u64, total), file_size));
    const size = in_file -| hdr_bytes;
    if (size > 0xA0000) return error.Format;
    return .{
        .exe = true,
        .size = size,
        .file_off = hdr_bytes,
        .paras = (size + 15) / 16,
        .min_extra = rd16(&hdr, 0x0A),
        .max_extra = rd16(&hdr, 0x0C),
        .ss = rd16(&hdr, 0x0E),
        .sp = rd16(&hdr, 0x10),
        .ip = rd16(&hdr, 0x14),
        .cs = rd16(&hdr, 0x16),
        .relocs = rd16(&hdr, 0x06),
        .reloc_off = rd16(&hdr, 0x18),
    };
}

/// Reads the image to `seg`:0 and, for an MZ, adds `factor` to each
/// relocated word.
pub fn load(host: Host, fd: i32, mem: *Memory, img: *const Image, seg: u16, factor: u16) Err!void {
    if (host.seek(fd, img.file_off, .set) < 0) return error.Read;
    var at = Memory.lin(seg, 0);
    var left = img.size;
    while (left > 0) {
        const chunk = @min(left, 0x8000);
        const dst = mem.bytes(at, chunk);
        if (dst.len < chunk) return error.Read;
        const got = host.read(fd, dst);
        if (got < 0) return error.Read;
        if (got == 0) break; // (short file: the rest stays as it was)
        const g: u32 = @intCast(got);
        at += g;
        left -= g;
    }
    if (!img.exe or img.relocs == 0) return;
    if (host.seek(fd, img.reloc_off, .set) < 0) return error.Read;
    var done: u32 = 0;
    var buf: [256]u8 = undefined;
    while (done < img.relocs) {
        const batch = @min(@as(u32, img.relocs) - done, 64);
        const want = buf[0 .. batch * 4];
        const got = host.read(fd, want);
        if (got != @as(i32, @intCast(want.len))) return error.Format;
        var i: u32 = 0;
        while (i < batch) : (i += 1) {
            const off = rd16(want, i * 4);
            const s = rd16(want, i * 4 + 2);
            const a = Memory.lin(seg +% s, off);
            mem.wr16(a, mem.rd16(a) +% factor);
        }
        done += batch;
    }
}
