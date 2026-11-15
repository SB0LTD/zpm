//! @zpm/nvidia vbios — an NVIDIA card's VBIOS, read for the one thing a
//! Turing GSP boot needs from it: FWSEC, the signed falcon microcode the
//! card carries, which sets up the firmware's protected region (WPR2) when
//! run on the GSP falcon with the FRTS command (turing.sig).
//!
//! The ROM is a chain of PCI expansion ROM images (0xaa55, a PCIR and
//! NVIDIA's NPDE after it). The first is the x86 VBIOS and holds the BIT
//! table ("\xff\xb8BIT"); a later image of type 0xe0 holds the falcon
//! microcode, and addresses past the first image's end mean that image
//! (`Rom.at`). BIT's token 'p' (version 2) points at a table of falcon
//! applications; the one of type 0x85 is FWSEC, behind a descriptor that
//! says where its code and data go in the falcon and where in its data the
//! command interface is (the "DMEM mapper", which this patches with the
//! command and where FRTS goes in VRAM).
//!
//! The descriptor has two versions. Version 2 (Turing; GA100) is loaded
//! through the generic falcon bootloader (linux-firmware's
//! nvidia/tu102/acr/bl.bin) and needs no signature patched in: that is
//! what is here. Version 3 (GA102 on) carries signatures picked by fuses:
//! found, it is named and refused.
//!
//! Layouts and the walk are nouveau's (nvkm/subdev/bios/image.c, pcir.c,
//! npde.c, bit.c, pmu.c, base.c, shadowrom.c and nvkm/subdev/gsp/fwsec.c:
//! MIT), used as documentation only. The blobs are only located, copied and
//! patched where NVIDIA's own drivers patch them; nothing of them is
//! decoded.
//!
//! Allocation-free and pure: the ROM is the caller's bytes (Galaxy reads
//! them from the card's PROM window, BAR0 + 0x300000).

const std = @import("std");

pub const Error = error{
    /// A read ran past the bytes given.
    Short,
    /// Not a PCI expansion ROM image where one should be.
    NoImage,
    /// No BIT table in the first image.
    NoBit,
    /// BIT has no falcon table (token 'p', version 2).
    NoFalconTable,
    /// The falcon table has no FWSEC (type 0x85).
    NoFwsec,
    /// FWSEC's descriptor or command interface is not the layout this reads.
    BadFwsec,
    /// A version 3 descriptor (Ampere and later): not booted here.
    Version3,
};

/// What went wrong, in words for the log.
pub fn why(e: Error) []const u8 {
    return switch (e) {
        error.Short => "the VBIOS is shorter than its own tables say",
        error.NoImage => "no PCI ROM image (0xaa55 and a PCIR) where one should be",
        error.NoBit => "no BIT table in the VBIOS",
        error.NoFalconTable => "BIT has no falcon table (token 'p', version 2)",
        error.NoFwsec => "the VBIOS has no FWSEC (falcon application 0x85)",
        error.BadFwsec => "FWSEC's descriptor or command interface is not the known layout",
        error.Version3 => "FWSEC has a version 3 descriptor (Ampere or later: its signatures are picked by fuses), not Turing's version 2",
    };
}

/// The PROM window is 1 MiB of BAR0 at 0x300000.
pub const PROM: u32 = 0x300000;
pub const PROM_BYTES: u32 = 0x100000;
/// The function's PCI configuration space as BAR0 mirrors it before GB20x
/// (0x88000), and its ROM shadow enable there (register 0x50, bit 0): the
/// PROM window reads the ROM only while the shadow is off.
pub const CFG_ROM_SHADOW: u32 = 0x50;

const IFR_SIGNATURE: u32 = 0x4947_564e; // "NVGI"
const ROM_DIRECTORY: u32 = 0x4452_4652; // "RFRD"

/// Where in the PROM window the PCI ROM starts: 0, or past an IFR header
/// (nouveau's nvbios_prom_init). `ctx.rd(offset)` reads a word of the
/// window. Null: an IFR header this does not know, or one that leads
/// nowhere.
pub fn romOffset(ctx: anytype) ?u32 {
    const fixed0: u32 = ctx.rd(0);
    if (fixed0 != IFR_SIGNATURE) return 0;
    const fixed1: u32 = ctx.rd(4);
    const version = (fixed1 >> 8) & 0xff;
    var off: u32 = 0;
    switch (version) {
        1, 2 => {
            const data_size = (fixed1 >> 16) & 0x7fff;
            off = ctx.rd(data_size + 4);
        },
        3 => {
            const data_size = ctx.rd(8) & 0x000f_ffff;
            if (data_size >= PROM_BYTES) return null;
            const dir = ctx.rd(data_size) +% 4096;
            if (dir >= PROM_BYTES - 12 or ctx.rd(dir) != ROM_DIRECTORY) return null;
            off = ctx.rd(dir + 8);
        },
        else => return null,
    }
    if (off >= PROM_BYTES) return null;
    if (ctx.rd(off) & 0xffff != 0xaa55) return null;
    return off;
}

fn rd8(d: []const u8, at: u32) Error!u32 {
    if (at >= d.len) return error.Short;
    return d[at];
}
fn rd16(d: []const u8, at: u32) Error!u32 {
    if (@as(u64, at) + 2 > d.len) return error.Short;
    return std.mem.readInt(u16, d[at..][0..2], .little);
}
fn rd32(d: []const u8, at: u32) Error!u32 {
    if (@as(u64, at) + 4 > d.len) return error.Short;
    return std.mem.readInt(u32, d[at..][0..4], .little);
}

/// One image of the chain.
pub const Image = struct { base: u32, size: u32, kind: u8, last: bool };

/// The header of an image is looked for in its first 4 KiB (nouveau's
/// shadow_image fetches that much before it parses).
pub const HEADER_BYTES: u32 = 0x1000;

/// The image at `base` (nvbios_imagen): its signature, PCIR and, unless it
/// is an EFI image... type 0x70 has no NPDE and ends the chain.
pub fn imageAt(d: []const u8, base: u32) Error!Image {
    switch (try rd16(d, base)) {
        0xaa55, 0xbb77, 0x4e56 => {},
        else => return error.NoImage,
    }
    const ptr = try rd16(d, base + 0x18);
    if (ptr == 0) return error.NoImage;
    const pcir = base + ptr;
    switch (try rd32(d, pcir)) {
        0x5249_4350, 0x5349_4752, 0x5344_504e => {}, // PCIR, RGIS, NPDS
        else => return error.NoImage,
    }
    const hdr = try rd16(d, pcir + 0x0a);
    var im = Image{
        .base = base,
        .size = (try rd16(d, pcir + 0x10)) * 512,
        .kind = @intCast(try rd8(d, pcir + 0x14)),
        .last = (try rd8(d, pcir + 0x15)) & 0x80 != 0,
    };
    if (im.kind == 0x70) {
        im.last = true;
        return im;
    }
    const npde = (pcir + hdr + 0x0f) & ~@as(u32, 0x0f);
    // (no NPDE: the PCIR's own size and last flag stand)
    const sig = rd32(d, npde) catch return im;
    if (sig != 0x4544_504e) return im; // "NPDE"
    im.size = (try rd16(d, npde + 0x08)) * 512;
    im.last = (try rd8(d, npde + 0x0a)) & 0x80 != 0;
    return im;
}

/// How many bytes of the ROM are needed, given `have` of them from its
/// start: more than `have.len` while the chain goes on past what was read
/// (read up to there and ask again), `have.len` or less once every image is
/// whole. An image that does not parse ends the chain where it starts, as
/// nouveau's walk does, unless it is the first.
pub fn need(have: []const u8) Error!u32 {
    var base: u32 = 0;
    var n: u32 = 0;
    while (n < 16) : (n += 1) {
        if (@as(u64, base) + HEADER_BYTES > have.len) return base + HEADER_BYTES;
        const im = imageAt(have, base) catch |e| {
            if (n == 0) return e;
            return base;
        };
        if (im.size == 0) return if (n == 0) error.NoImage else base;
        if (@as(u64, im.base) + im.size > have.len) return im.base + im.size;
        if (im.last) return im.base + im.size;
        base = im.base + im.size;
    }
    return base;
}

/// The ROM, opened: its images' places and its BIT table.
pub const Rom = struct {
    data: []const u8,
    /// The first image's size, and where the first image of type 0xe0
    /// starts (0: none): an address at or past the first's end is in that
    /// one (nouveau's nvbios_addr).
    image0_size: u32 = 0,
    imaged_addr: u32 = 0,
    images: u32 = 0,
    /// Where the BIT table is.
    bit: u32 = 0,

    /// The index in `data` of VBIOS address `addr`, when `n` bytes from it
    /// are inside the ROM.
    pub fn at(r: *const Rom, addr: u32, n: u32) Error!u32 {
        var a: u64 = addr;
        if (addr >= r.image0_size and r.imaged_addr != 0) a = a - r.image0_size + r.imaged_addr;
        if (a + n > r.data.len) return error.Short;
        return @intCast(a);
    }

    pub fn u8At(r: *const Rom, addr: u32) Error!u32 {
        return r.data[try r.at(addr, 1)];
    }
    pub fn u16At(r: *const Rom, addr: u32) Error!u32 {
        return std.mem.readInt(u16, r.data[try r.at(addr, 2)..][0..2], .little);
    }
    pub fn u32At(r: *const Rom, addr: u32) Error!u32 {
        return std.mem.readInt(u32, r.data[try r.at(addr, 4)..][0..4], .little);
    }
};

/// The ROM in `data` (all of its images: `need` said so), opened.
pub fn open(data: []const u8) Error!Rom {
    var r = Rom{ .data = data };
    var base: u32 = 0;
    var n: u32 = 0;
    while (n < 16) : (n += 1) {
        const im = imageAt(data, base) catch |e| {
            if (n == 0) return e;
            break;
        };
        if (im.size == 0) break;
        if (n == 0) r.image0_size = im.size;
        if (n != 0 and r.imaged_addr == 0 and im.kind == 0xe0) r.imaged_addr = im.base;
        r.images = n + 1;
        if (im.last) break;
        base = im.base + im.size;
        if (base >= data.len) break;
    }
    if (r.image0_size == 0) return error.NoImage;
    r.bit = @intCast(std.mem.indexOf(u8, data, "\xff\xb8BIT") orelse return error.NoBit);
    if (r.bit == 0) return error.NoBit;
    return r;
}

/// A BIT token's entry.
pub const Bit = struct { version: u8, length: u32, offset: u32 };

/// BIT's entry for token `id` (nouveau's bit_entry).
pub fn bitEntry(r: *const Rom, id: u8) Error!?Bit {
    const entries = try r.u8At(r.bit + 10);
    const size = try r.u8At(r.bit + 9);
    var e = r.bit + 12;
    var i: u32 = 0;
    while (i < entries) : (i += 1) {
        if (try r.u8At(e) == id) return .{
            .version = @intCast(try r.u8At(e + 1)),
            .length = try r.u16At(e + 2),
            .offset = try r.u16At(e + 4),
        };
        e += size;
    }
    return null;
}

/// FWSEC, as the VBIOS's version 2 descriptor gives it (nouveau's
/// nvkm_falcon_ucode_desc_v2), and where its image is in the ROM's bytes.
pub const Fwsec = struct {
    /// The image in `Rom.data`: IMEMLoadSize bytes of code, then the data.
    image_at: u32,
    image_len: u32,
    /// Where the command interface is, from the data's start.
    interface_offset: u32,
    imem_phys_base: u32,
    imem_load_size: u32,
    imem_virt_base: u32,
    imem_sec_base: u32,
    imem_sec_size: u32,
    /// Where the data starts in the image, where it goes in the falcon's
    /// data memory, and how much of it.
    dmem_offset: u32,
    dmem_phys_base: u32,
    dmem_load_size: u32,

    pub fn image(f: *const Fwsec, r: *const Rom) []const u8 {
        return r.data[f.image_at..][0..f.image_len];
    }
};

/// The falcon application FWSEC's type in the VBIOS's table.
pub const APP_FWSEC: u8 = 0x85;

/// FWSEC in the ROM (nouveau's nvkm_gsp_fwsec_init: BIT 'p', the falcon
/// table's entry of type 0x85, its descriptor).
pub fn fwsec(r: *const Rom) Error!Fwsec {
    const p = (try bitEntry(r, 'p')) orelse return error.NoFalconTable;
    if (p.version != 2 or p.length < 4) return error.NoFalconTable;
    const table = try r.u32At(p.offset);
    if (table == 0) return error.NoFalconTable;
    const hdr = try r.u8At(table + 1);
    const len = try r.u8At(table + 2);
    const cnt = try r.u8At(table + 3);
    var desc_addr: u32 = 0;
    var i: u32 = 0;
    while (i < cnt) : (i += 1) {
        const e = table + hdr + i * len;
        if (try r.u8At(e) == APP_FWSEC) {
            desc_addr = try r.u32At(e + 2);
            break;
        }
    }
    if (desc_addr == 0) return error.NoFwsec;
    const word = try r.u32At(desc_addr);
    if (word & 1 == 0) return error.BadFwsec;
    const size = word >> 16;
    const version = (word >> 8) & 0xff;
    if (version == 3) return error.Version3;
    if (version != 2 or size < 60) return error.BadFwsec;
    // (the descriptor and the image behind it are in one image of the ROM:
    // the same fix-up for both)
    const d = try r.at(desc_addr, size);
    const w = struct {
        fn at(b: []const u8, i_: u32) u32 {
            return std.mem.readInt(u32, b[i_ * 4 ..][0..4], .little);
        }
    }.at;
    const b = r.data[d..][0..size];
    var f = Fwsec{
        .image_at = d + size,
        .image_len = 0,
        .interface_offset = w(b, 4),
        .imem_phys_base = w(b, 5),
        .imem_load_size = w(b, 6),
        .imem_virt_base = w(b, 7),
        .imem_sec_base = w(b, 8),
        .imem_sec_size = w(b, 9),
        .dmem_offset = w(b, 10),
        .dmem_phys_base = w(b, 11),
        .dmem_load_size = w(b, 12),
    };
    const total = @as(u64, f.imem_load_size) + f.dmem_load_size;
    if (total == 0 or total > 0x10_0000 or @as(u64, f.image_at) + total > r.data.len) return error.BadFwsec;
    f.image_len = @intCast(total);
    if (f.imem_sec_size > f.imem_load_size or @as(u64, f.dmem_offset) + f.dmem_load_size > total) return error.BadFwsec;
    if (f.interface_offset >= f.dmem_load_size) return error.BadFwsec;
    return f;
}

/// FWSEC's commands (the DMEM mapper's init_cmd).
pub const CMD_FRTS: u32 = 0x15;
pub const CMD_SB: u32 = 0x19;
/// The command interface's application id for the DMEM mapper.
const APPIF_DMEMMAPPER: u32 = 4;
/// NVFW_FRTS_CMD_REGION_TYPE_FB: FRTS goes in VRAM.
const FRTS_REGION_FB: u32 = 2;

fn put32(b: []u8, at: usize, v: u32) Error!void {
    if (at + 4 > b.len) return error.BadFwsec;
    std.mem.writeInt(u32, b[at..][0..4], v, .little);
}
fn get32(b: []const u8, at: usize) Error!u32 {
    if (at + 4 > b.len) return error.BadFwsec;
    return std.mem.readInt(u32, b[at..][0..4], .little);
}

/// A copy of FWSEC's image (`image`, the caller's, as long as `f.image_len`)
/// told what to do (nouveau's nvkm_gsp_fwsec_patch): the DMEM mapper's
/// command set to `cmd`, its input buffer to "read the VBIOS" and, for
/// FRTS, the region [frts_addr, frts_addr + frts_size) of VRAM.
pub fn patch(image: []u8, f: *const Fwsec, cmd: u32, frts_addr: u64, frts_size: u64) Error!void {
    if (image.len < f.image_len) return error.BadFwsec;
    const dmem = image[f.dmem_offset..][0..f.dmem_load_size];
    const hdr: usize = f.interface_offset;
    if (hdr + 4 > dmem.len or dmem[hdr] != 1) return error.BadFwsec;
    const hdr_len: usize = dmem[hdr + 1];
    const ent_len: usize = dmem[hdr + 2];
    const cnt: usize = dmem[hdr + 3];
    if (ent_len < 8) return error.BadFwsec;
    var i: usize = 0;
    while (i < cnt) : (i += 1) {
        const app = hdr + hdr_len + i * ent_len;
        if (try get32(dmem, app) != APPIF_DMEMMAPPER) continue;
        const map: usize = try get32(dmem, app + 4);
        // (the mapper: signature, version and size, the command buffers'
        // offsets and sizes from +8, init_cmd at +44)
        try put32(dmem, map + 44, cmd);
        const in: usize = try get32(dmem, map + 8);
        // read_vbios {ver 1, hdr 24, addr 0 (u64), size 0, flags 2}
        try put32(dmem, in + 0, 1);
        try put32(dmem, in + 4, 24);
        try put32(dmem, in + 8, 0);
        try put32(dmem, in + 12, 0);
        try put32(dmem, in + 16, 0);
        try put32(dmem, in + 20, 2);
        if (cmd == CMD_FRTS) {
            // frts_region {ver 1, hdr 20, addr >> 12, size >> 12, type FB}
            try put32(dmem, in + 24, 1);
            try put32(dmem, in + 28, 20);
            try put32(dmem, in + 32, @intCast(frts_addr >> 12));
            try put32(dmem, in + 36, @intCast(frts_size >> 12));
            try put32(dmem, in + 40, FRTS_REGION_FB);
        }
        return;
    }
    return error.BadFwsec;
}

// ── Host tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

/// A made-up ROM of three images: the x86 VBIOS (0x800 bytes, with BIT and
/// its token 'p'), an EFI-like image (type 0x03) and the falcon image (type
/// 0xe0) holding the falcon table and FWSEC. Its addresses past the first
/// image mean the third (as a real card's do).
pub const TestRom = struct {
    bytes: [0x2800]u8 = [_]u8{0} ** 0x2800,
    /// FWSEC's image in `bytes`, and where its data starts in it.
    image_at: u32 = 0,
    in_buffer: u32 = 0,

    fn w16(t: *TestRom, at: usize, v: u16) void {
        std.mem.writeInt(u16, t.bytes[at..][0..2], v, .little);
    }
    fn w32(t: *TestRom, at: usize, v: u32) void {
        std.mem.writeInt(u32, t.bytes[at..][0..4], v, .little);
    }

    fn image(t: *TestRom, base: usize, blocks: u16, kind: u8, last: bool) void {
        t.w16(base, 0xaa55);
        t.w16(base + 0x18, 0x20);
        const pcir = base + 0x20;
        @memcpy(t.bytes[pcir..][0..4], "PCIR");
        t.w16(pcir + 0x0a, 0x18);
        // (the PCIR's own size is a decoy: the NPDE's is the real one)
        t.w16(pcir + 0x10, 1);
        t.bytes[pcir + 0x14] = kind;
        t.bytes[pcir + 0x15] = 0;
        const npde = (pcir + 0x18 + 0x0f) & ~@as(usize, 0x0f);
        @memcpy(t.bytes[npde..][0..4], "NPDE");
        t.w16(npde + 8, blocks);
        t.bytes[npde + 0x0a] = if (last) 0x80 else 0;
    }

    pub fn build(t: *TestRom, version: u8) void {
        t.* = .{};
        t.image(0, 4, 0x00, false); // 0x000..0x800
        t.image(0x800, 8, 0x03, false); // 0x800..0x1800
        t.image(0x1800, 8, 0xe0, true); // 0x1800..0x2800
        // BIT at 0x100: 2 entries of 6 bytes from +12
        const bit = 0x100;
        @memcpy(t.bytes[bit..][0..5], "\xff\xb8BIT");
        t.bytes[bit + 9] = 6;
        t.bytes[bit + 10] = 2;
        t.bytes[bit + 12] = 'i';
        t.bytes[bit + 18] = 'p';
        t.bytes[bit + 19] = 2;
        t.w16(bit + 20, 4);
        t.w16(bit + 22, 0x180); // 'p' data at 0x180
        // the falcon table at VBIOS address 0x900: past image 0, so in the
        // 0xe0 image at 0x1800 + 0x100
        t.w32(0x180, 0x900);
        const table = 0x1800 + 0x100;
        t.bytes[table + 0] = 1;
        t.bytes[table + 1] = 6; // header
        t.bytes[table + 2] = 6; // entry
        t.bytes[table + 3] = 2; // count
        t.bytes[table + 6] = 0x05; // (another application)
        t.w32(table + 6 + 2, 0xa00);
        t.bytes[table + 12] = APP_FWSEC;
        t.w32(table + 12 + 2, 0xa00); // the descriptor at VBIOS 0xa00
        const desc = 0x1800 + 0x200;
        const size: u32 = 60;
        t.w32(desc, 1 | (@as(u32, version) << 8) | (size << 16));
        t.w32(desc + 4, 0x600); // StoredSize
        t.w32(desc + 16, 0x40); // InterfaceOffset (in the data)
        t.w32(desc + 20, 0); // IMEMPhysBase
        t.w32(desc + 24, 0x400); // IMEMLoadSize
        t.w32(desc + 28, 0); // IMEMVirtBase
        t.w32(desc + 32, 0x100); // IMEMSecBase
        t.w32(desc + 36, 0x300); // IMEMSecSize
        t.w32(desc + 40, 0x400); // DMEMOffset
        t.w32(desc + 44, 0); // DMEMPhysBase
        t.w32(desc + 48, 0x200); // DMEMLoadSize
        t.image_at = desc + size;
        for (t.bytes[t.image_at..][0..0x400], 0..) |*b, i| b.* = @truncate(i * 3 + 1);
        const dmem = t.image_at + 0x400;
        // the interface: version 1, header 4, entries of 8, two of them
        t.bytes[dmem + 0x40] = 1;
        t.bytes[dmem + 0x41] = 4;
        t.bytes[dmem + 0x42] = 8;
        t.bytes[dmem + 0x43] = 2;
        t.w32(dmem + 0x44, 1); // (another interface)
        t.w32(dmem + 0x48, 0x10);
        t.w32(dmem + 0x4c, APPIF_DMEMMAPPER);
        t.w32(dmem + 0x50, 0x80); // the mapper at data + 0x80
        t.w32(dmem + 0x80 + 8, 0x100); // cmd_in_buffer_offset
        t.w32(dmem + 0x80 + 12, 0x40);
        t.in_buffer = dmem + 0x100;
    }
};

test "vbios: the chain of images is read as far as it goes, then no further" {
    var t: TestRom = undefined;
    t.build(2);
    // nothing read: the first header
    try testing.expectEqual(@as(u32, 0x1000), try need(t.bytes[0..0]));
    // image 0 is whole in 0x1000, image 1's header is not
    try testing.expectEqual(@as(u32, 0x1800), try need(t.bytes[0..0x1000]));
    try testing.expectEqual(@as(u32, 0x2800), try need(t.bytes[0..0x1800]));
    try testing.expectEqual(@as(u32, 0x2800), try need(t.bytes[0..0x2800]));
    // no ROM signature
    var junk = [_]u8{0xff} ** 0x1000;
    try testing.expectError(error.NoImage, need(&junk));
    const im = try imageAt(&t.bytes, 0x1800);
    try testing.expectEqual(@as(u8, 0xe0), im.kind);
    try testing.expectEqual(@as(u32, 0x1000), im.size);
    try testing.expect(im.last);
}

test "vbios: addresses past the first image mean the falcon image; BIT and FWSEC found" {
    var t: TestRom = undefined;
    t.build(2);
    const r = try open(&t.bytes);
    try testing.expectEqual(@as(u32, 0x800), r.image0_size);
    try testing.expectEqual(@as(u32, 0x1800), r.imaged_addr);
    try testing.expectEqual(@as(u32, 3), r.images);
    try testing.expectEqual(@as(u32, 0x100), r.bit);
    try testing.expectEqual(@as(u32, 0x7ff), try r.at(0x7ff, 1));
    try testing.expectEqual(@as(u32, 0x1800), try r.at(0x800, 1));
    try testing.expectError(error.Short, r.at(0x1800, 1));
    const p = (try bitEntry(&r, 'p')).?;
    try testing.expectEqual(@as(u8, 2), p.version);
    try testing.expectEqual(@as(u32, 0x180), p.offset);
    try testing.expect((try bitEntry(&r, 'x')) == null);
    const f = try fwsec(&r);
    try testing.expectEqual(t.image_at, f.image_at);
    try testing.expectEqual(@as(u32, 0x600), f.image_len);
    try testing.expectEqual(@as(u32, 0x40), f.interface_offset);
    try testing.expectEqual(@as(u32, 0x100), f.imem_sec_base);
    try testing.expectEqual(@as(u32, 0x300), f.imem_sec_size);
    try testing.expectEqual(@as(u32, 0x400), f.dmem_offset);
    try testing.expectEqual(@as(u32, 0x200), f.dmem_load_size);
    try testing.expectEqual(@as(u8, 1), f.image(&r)[0]);
}

test "vbios: FWSEC's command interface patched for FRTS and for SB, the ROM untouched" {
    var t: TestRom = undefined;
    t.build(2);
    const r = try open(&t.bytes);
    const f = try fwsec(&r);
    var copy: [0x600]u8 = undefined;
    @memcpy(&copy, f.image(&r));
    try patch(&copy, &f, CMD_FRTS, 0x2_bfe0_0000, 0x10_0000);
    const dmem = copy[0x400..];
    try testing.expectEqual(CMD_FRTS, std.mem.readInt(u32, dmem[0x80 + 44 ..][0..4], .little));
    const in = dmem[0x100..];
    var words: [11]u32 = undefined;
    for (&words, 0..) |*w, i| w.* = std.mem.readInt(u32, in[i * 4 ..][0..4], .little);
    try testing.expectEqualSlices(u32, &.{ 1, 24, 0, 0, 0, 2, 1, 20, 0x2bfe00, 0x100, 2 }, &words);
    // (the code is as it was, and so is the ROM)
    try testing.expectEqualSlices(u8, f.image(&r)[0..0x400], copy[0..0x400]);
    try testing.expectEqual(@as(u8, 0), t.bytes[t.in_buffer]);
    // SB: the command and the read alone; no region
    @memcpy(&copy, f.image(&r));
    try patch(&copy, &f, CMD_SB, 0, 0);
    try testing.expectEqual(CMD_SB, std.mem.readInt(u32, copy[0x400 + 0x80 + 44 ..][0..4], .little));
    try testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, copy[0x400 + 0x100 + 24 ..][0..4], .little));
    // an interface without the mapper is refused
    @memcpy(&copy, f.image(&r));
    std.mem.writeInt(u32, copy[0x400 + 0x4c ..][0..4], 9, .little);
    try testing.expectError(error.BadFwsec, patch(&copy, &f, CMD_FRTS, 0, 0));
}

test "vbios: a version 3 descriptor is named, not booted; a ROM without FWSEC says so" {
    var t: TestRom = undefined;
    t.build(3);
    var r = try open(&t.bytes);
    try testing.expectError(error.Version3, fwsec(&r));
    t.build(2);
    t.bytes[0x1800 + 0x100 + 12] = 0x45; // (the debug FWSEC only)
    r = try open(&t.bytes);
    try testing.expectError(error.NoFwsec, fwsec(&r));
    t.build(2);
    t.bytes[0x100 + 18] = 'q';
    r = try open(&t.bytes);
    try testing.expectError(error.NoFalconTable, fwsec(&r));
    try testing.expect(why(error.Version3).len > 0);
}

test "vbios: the PROM window's ROM offset, with and without an IFR header" {
    const Win = struct {
        words: [64]u32 = [_]u32{0} ** 64,
        pub fn rd(w: *const @This(), off: u32) u32 {
            return if (off / 4 < w.words.len) w.words[off / 4] else 0xffff_ffff;
        }
    };
    var w = Win{};
    w.words[0] = 0xe9_4baa55; // (a plain ROM)
    try testing.expectEqual(@as(?u32, 0), romOffset(&w));
    // IFR version 1: data size 0x20 in fixed1, the offset at data + 4
    w = .{};
    w.words[0] = IFR_SIGNATURE;
    w.words[1] = (0x20 << 16) | (1 << 8);
    w.words[(0x20 + 4) / 4] = 0x80;
    w.words[0x80 / 4] = 0xaa55;
    try testing.expectEqual(@as(?u32, 0x80), romOffset(&w));
    // (an offset that leads to no ROM)
    w.words[0x80 / 4] = 0;
    try testing.expectEqual(@as(?u32, null), romOffset(&w));
    w.words[1] = 9 << 8;
    try testing.expectEqual(@as(?u32, null), romOffset(&w));
}
