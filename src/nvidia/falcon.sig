//! @zpm/nvidia falcon — NVIDIA's falcon microcontrollers as a driver sees
//! them before GSP-RM runs: their firmware files' containers, and the
//! register sequences that reset one, load a signed microcode into it and
//! run it to its halt. A Turing GPU boots GSP-RM with two of them
//! (turing.sig): FWSEC on the GSP's falcon (0x110000), then the booter on
//! SEC2's (0x840000 on Turing).
//!
//! Firmware containers:
//!
//! - every file starts with nvfw_bin_hdr {magic, version, size,
//!   header_offset, data_offset, data_size};
//! - the generic bootloader (nvidia/tu102/acr/bl.bin) has nvfw_bl_desc at
//!   header_offset: its start tag and where its code is. It is the small
//!   unsigned loader that pulls a heavy-secure microcode in by DMA and
//!   jumps to it: FWSEC, which lives in the VBIOS, is started through it;
//! - a booter (nvidia/tu102/gsp/booter_load-570.144.bin, booter_unload-)
//!   has nvfw_hs_header_v2 at header_offset (where its production
//!   signatures are and where one is patched into the image) and
//!   nvfw_hs_load_header_v2 behind that (its code, its heavy-secure
//!   application and its data). It is loaded word by word (PIO).
//!
//! Register sequences (a falcon's registers are offsets from its base):
//! reset (0x3c0, the memory scrub in 0x10c), no-context DMA (0x624, 0x10c),
//! PIO into code memory (0x180/0x184/0x188, each 256-byte block with its
//! tag, secure blocks marked) and data memory (0x1c0/0x1c4), the bootloader
//! descriptor that tells the generic bootloader what to fetch, and the
//! start (mailboxes 0x040/0x044, boot vector 0x104, CPUCTL 0x100) with the
//! wait for the halt.
//!
//! All of it is nouveau's (nvkm/falcon/base.c, fw.c, gm200.c, gp102.c,
//! v1.c, include/nvfw/fw.h, hs.h, flcn.h, nvkm/subdev/gsp/tu102.c: MIT),
//! used as documentation only. The blobs are located, copied and patched
//! with their own signature as NVIDIA's drivers patch them; nothing of
//! them is decoded.
//!
//! The hardware is reached through `io`, any value with `rd(addr) u32`,
//! `wr(addr, value)`, `nowUs() u64` and `pause()`: Galaxy's kernel gives
//! BAR0, the tests a `Model` that keeps what was loaded. Nothing here has
//! run on a card yet. Allocation-free.

const std = @import("std");

pub const Error = error{
    /// The file is shorter than its headers say.
    Short,
    /// A header's numbers do not fit the file or the falcon.
    BadHeader,
};

pub fn why(e: Error) []const u8 {
    return switch (e) {
        error.Short => "the file is shorter than its headers say",
        error.BadHeader => "its headers do not fit the file (or a falcon's memory)",
    };
}

fn rd32(b: []const u8, at: u64) Error!u32 {
    if (at + 4 > b.len) return error.Short;
    return std.mem.readInt(u32, b[@intCast(at)..][0..4], .little);
}

fn slice(b: []const u8, at: u64, len: u64) Error![]const u8 {
    if (at > b.len or len > b.len - at) return error.Short;
    return b[@intCast(at)..][0..@intCast(len)];
}

// ── Firmware containers ─────────────────────────────────────────────────────

/// nvfw_bin_hdr: where a file's header and data are.
pub const Bin = struct { header_offset: u32, data: []const u8 };

pub fn bin(file: []const u8) Error!Bin {
    const header_offset = try rd32(file, 12);
    const data_offset = try rd32(file, 16);
    const data_size = try rd32(file, 20);
    if (data_size == 0) return error.BadHeader;
    return .{ .header_offset = header_offset, .data = try slice(file, data_offset, data_size) };
}

/// The generic bootloader: its code, and the tag it is loaded and started
/// at (boot address = tag << 8).
pub const Bootloader = struct {
    start_tag: u32,
    code: []const u8,

    pub fn bootAddr(b: Bootloader) u32 {
        return b.start_tag << 8;
    }
};

/// nvfw_bl_desc {start_tag, dmem_load_off, code_off, code_size, data_off,
/// data_size} at the bin header's header_offset; the code is in the data.
pub fn bootloader(file: []const u8) Error!Bootloader {
    const h = try bin(file);
    const d: u64 = h.header_offset;
    const code_off = try rd32(file, d + 8);
    const code_size = try rd32(file, d + 12);
    // (PIO into code memory goes in whole 256-byte blocks)
    if (code_size == 0 or code_size & 0xff != 0) return error.BadHeader;
    return .{ .start_tag = try rd32(file, d), .code = try slice(h.data, code_off, code_size) };
}

/// A part of a microcode image and where it goes in the falcon.
pub const Seg = struct { img: u32 = 0, base: u32 = 0, size: u32 = 0 };

/// A booter: its image, the signature to patch into it, and its three
/// parts (nouveau's tu102_gsp_booter_ctor).
pub const Booter = struct {
    /// The image as the file has it (unsigned: `signed` copies and patches).
    image: []const u8,
    /// The first production signature, and where in the image it goes.
    sig: []const u8,
    sig_at: u32,
    /// How many production signatures the file has.
    sigs: u32,
    /// Non-secure code, the heavy-secure application, the data.
    nmem: Seg,
    imem: Seg,
    dmem: Seg,
    boot_addr: u32,

    /// The image with its signature patched in, in `out` (as long as the
    /// image): what is loaded.
    pub fn signed(b: *const Booter, out: []u8) Error![]u8 {
        if (out.len < b.image.len) return error.Short;
        @memcpy(out[0..b.image.len], b.image);
        @memcpy(out[b.sig_at..][0..b.sig.len], b.sig);
        return out[0..b.image.len];
    }
};

pub fn booter(file: []const u8) Error!Booter {
    const h = try bin(file);
    const hs: u64 = h.header_offset;
    // nvfw_hs_header_v2 {sig_prod_offset, sig_prod_size, patch_loc,
    // patch_sig, meta_data_offset, meta_data_size, num_sig, header_offset,
    // header_size}: patch_loc, patch_sig and num_sig are where in the file
    // those words are.
    const sig_prod_offset = try rd32(file, hs + 0);
    const sig_prod_size = try rd32(file, hs + 4);
    const loc = try rd32(file, try rd32(file, hs + 8));
    const sig = try rd32(file, try rd32(file, hs + 12));
    const cnt = try rd32(file, try rd32(file, hs + 24));
    const lh: u64 = try rd32(file, hs + 28);
    if (cnt == 0 or sig_prod_size == 0 or sig_prod_size % cnt != 0) return error.BadHeader;
    const sig_size = sig_prod_size / cnt;
    // nvfw_hs_load_header_v2 {os_code_offset, os_code_size, os_data_offset,
    // os_data_size, num_apps, app[]{offset, size, data_offset, data_size}}
    const os_code_offset = try rd32(file, lh + 0);
    const os_code_size = try rd32(file, lh + 4);
    const os_data_offset = try rd32(file, lh + 8);
    const os_data_size = try rd32(file, lh + 12);
    if (try rd32(file, lh + 16) == 0) return error.BadHeader;
    const app_offset = try rd32(file, lh + 20);
    const app_size = try rd32(file, lh + 24);
    const b = Booter{
        .image = h.data,
        .sig = try slice(file, @as(u64, sig_prod_offset) + sig, sig_size),
        .sig_at = loc,
        .sigs = cnt,
        .nmem = .{ .img = 0, .base = os_code_offset, .size = os_code_size },
        .imem = .{ .img = os_code_size, .base = app_offset, .size = app_size },
        .dmem = .{ .img = os_data_offset, .base = 0, .size = os_data_size },
        .boot_addr = os_code_offset,
    };
    if (@as(u64, loc) + sig_size > b.image.len) return error.BadHeader;
    for ([_]Seg{ b.nmem, b.imem, b.dmem }) |s| {
        if (s.size == 0 or @as(u64, s.img) + s.size > b.image.len) return error.BadHeader;
    }
    if (b.nmem.size & 0xff != 0 or b.imem.size & 0xff != 0 or b.dmem.size & 3 != 0) return error.BadHeader;
    return b;
}

/// flcn_bl_dmem_desc_v2 (packed, 84 bytes): what the generic bootloader
/// finds at the start of data memory. ctx_dma is the DMA index it fetches
/// through; the code and data are at `code_dma` and `data_dma` in system
/// memory.
pub const BL_DESC_BYTES = 84;
/// FALCON_DMAIDX_PHYS_SYS_NCOH: physical system memory, not coherent.
pub const DMAIDX_PHYS_SYS_NCOH: u32 = 4;

pub const BlDesc = struct {
    ctx_dma: u32 = DMAIDX_PHYS_SYS_NCOH,
    code_dma: u64,
    non_sec_code_off: u32,
    non_sec_code_size: u32,
    sec_code_off: u32,
    sec_code_size: u32,
    code_entry_point: u32 = 0,
    data_dma: u64,
    data_size: u32,

    pub fn bytes(d: BlDesc) [BL_DESC_BYTES]u8 {
        var b = [_]u8{0} ** BL_DESC_BYTES;
        // reserved[4], signature[4]: zero
        std.mem.writeInt(u32, b[32..36], d.ctx_dma, .little);
        std.mem.writeInt(u64, b[36..44], d.code_dma, .little);
        std.mem.writeInt(u32, b[44..48], d.non_sec_code_off, .little);
        std.mem.writeInt(u32, b[48..52], d.non_sec_code_size, .little);
        std.mem.writeInt(u32, b[52..56], d.sec_code_off, .little);
        std.mem.writeInt(u32, b[56..60], d.sec_code_size, .little);
        std.mem.writeInt(u32, b[60..64], d.code_entry_point, .little);
        std.mem.writeInt(u64, b[64..72], d.data_dma, .little);
        std.mem.writeInt(u32, b[72..76], d.data_size, .little);
        // argc, argv: zero
        return b;
    }
};

// ── The registers ───────────────────────────────────────────────────────────

/// The GSP's falcon, and SEC2's on Turing (nouveau's tu102_sec2_new: "TOP
/// info wasn't updated on Turing to reflect the PRI address change").
pub const GSP: u32 = 0x110000;
pub const SEC2_TURING: u32 = 0x840000;

pub const IRQSCLR: u32 = 0x004;
pub const IRQMCLR: u32 = 0x014;
pub const MAILBOX0: u32 = 0x040;
pub const MAILBOX1: u32 = 0x044;
pub const ITFEN: u32 = 0x048;
pub const OS: u32 = 0x080;
pub const RM: u32 = 0x084;
pub const CPUCTL: u32 = 0x100;
pub const BOOTVEC: u32 = 0x104;
pub const HWCFG: u32 = 0x108;
pub const DMACTL: u32 = 0x10c;
pub const CPUCTL_ALIAS: u32 = 0x130;
pub const IMEMC: u32 = 0x180;
pub const IMEMD: u32 = 0x184;
pub const IMEMT: u32 = 0x188;
pub const DMEMC: u32 = 0x1c0;
pub const DMEMD: u32 = 0x1c4;
pub const ENGINE: u32 = 0x3c0;
pub const FBIF_TRANSCFG: u32 = 0x600;
pub const FBIF_CTL: u32 = 0x624;
/// The GSP's RISC-V side on Turing: its registers start 0x1000 past the
/// falcon's, and bit 0 of +0x240 says the RISC-V core is the one running
/// (nouveau's tu102_flcn_riscv_active).
pub const RISCV: u32 = 0x1000;
pub const RISCV_ACTIVE: u32 = RISCV + 0x240;

pub const CPUCTL_STARTCPU: u32 = 1 << 1;
pub const CPUCTL_HALTED: u32 = 1 << 4;
pub const CPUCTL_ALIAS_EN: u32 = 1 << 6;

/// How long a falcon's memory scrub may take after a reset, and a
/// microcode's run to its halt.
pub const SCRUB_US: u64 = 10_000;
pub const HALT_US: u64 = 2_000_000;

fn mask(io: anytype, addr: u32, clear: u32, set: u32) void {
    io.wr(addr, (io.rd(addr) & ~clear) | set);
}

/// Wait up to `us` for (rd(addr) & bits) == want; the condition is looked
/// at once more after the time is up (a pause can be long).
fn poll(io: anytype, addr: u32, bits: u32, want: u32, us: u64) bool {
    const end = io.nowUs() + us;
    while (true) {
        if (io.rd(addr) & bits == want) return true;
        if (io.nowUs() >= end) return io.rd(addr) & bits == want;
        io.pause();
    }
}

fn spin(io: anytype, us: u64) void {
    const end = io.nowUs() + us;
    while (io.nowUs() < end) io.pause();
}

/// The falcon's memory scrub after a reset is done (gm200's
/// reset_wait_mem_scrubbing; MAILBOX0 is read and written back first, as
/// nouveau does).
pub fn waitScrub(io: anytype, base: u32) bool {
    mask(io, base + MAILBOX0, 0, 0);
    return poll(io, base + DMACTL, 0x6, 0, SCRUB_US);
}

/// The engine's own reset, pulsed (gp102_flcn_reset_eng).
pub fn resetEngine(io: anytype, base: u32) bool {
    mask(io, base + ENGINE, 1, 1);
    spin(io, 10);
    mask(io, base + ENGINE, 1, 0);
    return waitScrub(io, base);
}

/// The falcon reset as nouveau's nvkm_falcon_reset does it with GSP-RM in
/// charge (no PMC bit is touched then: its mc subdevice is not there):
/// interfaces off, interrupts masked, the engine reset; then the engine
/// reset again, the scrub, and PMC_BOOT_0 (`boot0`) in the RM register.
pub fn reset(io: anytype, base: u32, boot0: u32) bool {
    mask(io, base + ITFEN, 0x3, 0);
    io.wr(base + IRQMCLR, 0xffff_ffff);
    if (!resetEngine(io, base)) return false;
    if (!resetEngine(io, base)) return false;
    if (!waitScrub(io, base)) return false;
    io.wr(base + RM, boot0);
    return true;
}

/// DMA without a context (gm200_flcn_fw_load with no instance block):
/// physical addresses allowed, the DMA control cleared.
pub fn noContext(io: anytype, base: u32) void {
    mask(io, base + FBIF_CTL, 0x80, 0x80);
    io.wr(base + DMACTL, 0);
}

/// How much code memory the falcon has, in bytes (HWCFG).
pub fn codeLimit(io: anytype, base: u32) u32 {
    return (io.rd(base + HWCFG) & 0x1ff) << 8;
}

/// `data` into code memory at `at` through port 0, in 256-byte blocks
/// tagged from `tag` on, marked secure when `secure` (nouveau's
/// gm200_flcn_pio_imem_wr). Its length is a multiple of 256.
pub fn loadCode(io: anytype, base: u32, data: []const u8, at: u32, tag: u32, secure: bool) void {
    io.wr(base + IMEMC, (if (secure) @as(u32, 1) << 28 else 0) | (1 << 24) | at);
    var t = tag;
    var off: usize = 0;
    while (off + 0x100 <= data.len) : (off += 0x100) {
        io.wr(base + IMEMT, t);
        t += 1;
        var k: usize = 0;
        while (k < 0x100) : (k += 4) io.wr(base + IMEMD, std.mem.readInt(u32, data[off + k ..][0..4], .little));
    }
}

/// `data` into data memory at `at` through port 0 (whole words).
pub fn loadData(io: anytype, base: u32, data: []const u8, at: u32) void {
    io.wr(base + DMEMC, (1 << 24) | at);
    var off: usize = 0;
    while (off + 4 <= data.len) : (off += 4) io.wr(base + DMEMD, std.mem.readInt(u32, data[off..][0..4], .little));
}

/// A booter's three parts loaded by PIO from its signed image
/// (gm200_flcn_fw_load without a bootloader).
pub fn loadBooter(io: anytype, base: u32, b: *const Booter, image: []const u8) void {
    noContext(io, base);
    loadCode(io, base, image[b.nmem.img..][0..b.nmem.size], b.nmem.base, b.nmem.base >> 8, false);
    loadCode(io, base, image[b.imem.img..][0..b.imem.size], b.imem.base, b.imem.base >> 8, true);
    loadData(io, base, image[b.dmem.img..][0..b.dmem.size], b.dmem.base);
}

/// A microcode started through the generic bootloader (gm200_flcn_fw_load
/// with one, and tu102_gsp_fwsec_load_bld): the bootloader at the top of
/// code memory under its tag, the descriptor at the start of data memory,
/// and the DMA index it names set to physical, non-coherent system memory.
/// False when the bootloader does not fit the falcon's code memory.
pub fn loadWithBootloader(io: anytype, base: u32, bl: Bootloader, desc: BlDesc) bool {
    noContext(io, base);
    const limit = codeLimit(io, base);
    if (bl.code.len > limit) return false;
    loadCode(io, base, bl.code, limit - @as(u32, @intCast(bl.code.len)), bl.start_tag, false);
    mask(io, base + FBIF_TRANSCFG + desc.ctx_dma * 4, 0x7, 0x5);
    const d = desc.bytes();
    loadData(io, base, &d, 0);
    return true;
}

/// How a microcode's run ended.
pub const Run = struct {
    /// It halted within HALT_US.
    halted: bool,
    mbox0: u32,
    mbox1: u32,

    /// It halted with MAILBOX0 zero: what every one of these microcodes
    /// leaves when it did its work.
    pub fn ok(r: Run) bool {
        return r.halted and r.mbox0 == 0;
    }
};

/// The loaded microcode run from `boot_addr` with the mailboxes set, to
/// its halt (gm200_flcn_fw_boot).
pub fn run(io: anytype, base: u32, boot_addr: u32, mbox0: u32, mbox1: ?u32) Run {
    io.wr(base + MAILBOX0, mbox0);
    if (mbox1) |m| io.wr(base + MAILBOX1, m);
    io.wr(base + BOOTVEC, boot_addr);
    io.wr(base + CPUCTL, CPUCTL_STARTCPU);
    const done = poll(io, base + CPUCTL, CPUCTL_HALTED, CPUCTL_HALTED, HALT_US);
    return .{ .halted = done, .mbox0 = io.rd(base + MAILBOX0), .mbox1 = io.rd(base + MAILBOX1) };
}

/// The falcon started where it stands (nvkm_falcon_v1_start): through the
/// alias register when the microcode left the CPU control locked.
pub fn start(io: anytype, base: u32) void {
    if (io.rd(base + CPUCTL) & CPUCTL_ALIAS_EN != 0) io.wr(base + CPUCTL_ALIAS, CPUCTL_STARTCPU) else io.wr(base + CPUCTL, CPUCTL_STARTCPU);
}

pub fn halted(io: anytype, base: u32) bool {
    return io.rd(base + CPUCTL) & CPUCTL_HALTED != 0;
}

pub fn waitHalt(io: anytype, base: u32) bool {
    return poll(io, base + CPUCTL, CPUCTL_HALTED, CPUCTL_HALTED, HALT_US);
}

/// The GSP's RISC-V core is running (Turing's register).
pub fn riscvActive(io: anytype, base: u32) bool {
    return io.rd(base + RISCV_ACTIVE) & 1 != 0;
}

// ── A falcon for the tests ──────────────────────────────────────────────────

/// A falcon's registers as the sequences above use them, remembering what
/// was loaded: code memory with each block's tag and secure mark, data
/// memory, the resets, and each start. `on_start` stands for the
/// microcode: it sees the mailboxes and the memories and leaves what the
/// real one would (MAILBOX0, other registers through its own means). The
/// tests' own; a few hundred KiB, so keep it static.
pub const Model = struct {
    pub const CODE = 0x10000;
    pub const DATA = 0x10000;

    code: [CODE]u8 = [_]u8{0} ** CODE,
    tags: [CODE / 0x100]u16 = [_]u16{0xffff} ** (CODE / 0x100),
    secure: [CODE / 0x100]bool = [_]bool{false} ** (CODE / 0x100),
    data: [DATA]u8 = [_]u8{0} ** DATA,
    regs: [0x400]u32 = [_]u32{0} ** 0x400,
    /// Code memory in bytes (what HWCFG says).
    code_limit: u32 = 0x10000,
    imem_at: u32 = 0,
    imem_secure: bool = false,
    dmem_at: u32 = 0,
    resets: u32 = 0,
    starts: u32 = 0,
    /// A start left the falcon running as a RISC-V core (GSP-RM's).
    riscv: bool = false,
    /// A reset's scrub never finishes.
    stuck_scrub: bool = false,
    /// The microcode never halts.
    hang: bool = false,
    /// The microcode (null: it halts with MAILBOX0 zero).
    on_start: ?*const fn (m: *Model) void = null,
    ctx: ?*anyopaque = null,

    pub fn rd(m: *Model, reg: u32) u32 {
        return switch (reg) {
            HWCFG => (m.code_limit >> 8) & 0x1ff,
            DMACTL => if (m.stuck_scrub) 0x6 else m.regs[DMACTL / 4],
            RISCV_ACTIVE => @intFromBool(m.riscv),
            else => if (reg / 4 < m.regs.len) m.regs[reg / 4] else 0xbadf_5040,
        };
    }

    pub fn wr(m: *Model, reg: u32, v: u32) void {
        switch (reg) {
            IMEMC => {
                m.imem_at = v & 0x00ff_fffc;
                m.imem_secure = v & (1 << 28) != 0;
            },
            IMEMT => {
                const blk = m.imem_at >> 8;
                if (blk < m.tags.len) {
                    m.tags[blk] = @truncate(v);
                    m.secure[blk] = m.imem_secure;
                }
            },
            IMEMD => {
                if (m.imem_at + 4 <= CODE) std.mem.writeInt(u32, m.code[m.imem_at..][0..4], v, .little);
                m.imem_at += 4;
            },
            DMEMC => m.dmem_at = v & 0x00ff_fffc,
            DMEMD => {
                if (m.dmem_at + 4 <= DATA) std.mem.writeInt(u32, m.data[m.dmem_at..][0..4], v, .little);
                m.dmem_at += 4;
            },
            ENGINE => {
                if (m.regs[ENGINE / 4] & 1 != 0 and v & 1 == 0) {
                    // (out of reset: memories scrubbed, the core halted)
                    m.resets += 1;
                    m.riscv = false;
                    m.regs[CPUCTL / 4] = CPUCTL_HALTED;
                    @memset(&m.code, 0);
                    @memset(&m.data, 0);
                    @memset(&m.tags, 0xffff);
                    @memset(&m.secure, false);
                }
                m.regs[ENGINE / 4] = v;
            },
            CPUCTL, CPUCTL_ALIAS => {
                if (v & CPUCTL_STARTCPU == 0) return;
                m.starts += 1;
                m.regs[CPUCTL / 4] &= ~CPUCTL_HALTED;
                if (m.hang) return;
                if (m.on_start) |f| f(m) else m.regs[MAILBOX0 / 4] = 0;
                if (!m.riscv) m.regs[CPUCTL / 4] |= CPUCTL_HALTED;
            },
            else => if (reg / 4 < m.regs.len) {
                m.regs[reg / 4] = v;
            },
        }
    }
};

/// One falcon at address 0 and a clock, for this file's tests (turing.sig
/// has a GPU's worth).
const TestIo = struct {
    m: *Model,
    now: u64 = 0,

    pub fn rd(t: *TestIo, addr: u32) u32 {
        return t.m.rd(addr);
    }
    pub fn wr(t: *TestIo, addr: u32, v: u32) void {
        t.m.wr(addr, v);
    }
    pub fn nowUs(t: *TestIo) u64 {
        return t.now;
    }
    pub fn pause(t: *TestIo) void {
        t.now += 5;
    }
};

// ── Host tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

fn w32(b: []u8, at: usize, v: u32) void {
    std.mem.writeInt(u32, b[at..][0..4], v, .little);
}

/// A made-up booter file: bin header, hs header v2 with its three
/// indirect words, two 16-byte signatures, the load header, then an image
/// of 0x100 non-secure code, 0x200 of application and 0x40 of data whose
/// word at 0x10 is where the signature goes.
pub fn fakeBooter(f: *[0x600]u8) []const u8 {
    @memset(f, 0);
    w32(f, 0, 0x10de);
    w32(f, 12, 0x20); // header_offset
    w32(f, 16, 0x200); // data_offset
    w32(f, 20, 0x340); // data_size
    const hs = 0x20;
    w32(f, hs + 0, 0x80); // sig_prod_offset
    w32(f, hs + 4, 32); // sig_prod_size: two signatures
    w32(f, hs + 8, 0x60); // patch_loc is at 0x60
    w32(f, hs + 12, 0x64); // patch_sig is at 0x64
    w32(f, hs + 24, 0x68); // num_sig is at 0x68
    w32(f, hs + 28, 0xc0); // header_offset: the load header
    w32(f, 0x60, 0x310); // the signature goes at image + 0x310
    w32(f, 0x64, 0); // the first signature
    w32(f, 0x68, 2);
    for (f[0x80..0xa0], 0..) |*b, i| b.* = @truncate(0xa0 + i);
    const lh = 0xc0;
    w32(f, lh + 0, 0); // os_code_offset
    w32(f, lh + 4, 0x100); // os_code_size
    w32(f, lh + 8, 0x300); // os_data_offset
    w32(f, lh + 12, 0x40); // os_data_size
    w32(f, lh + 16, 1); // num_apps
    w32(f, lh + 20, 0x100); // app[0].offset
    w32(f, lh + 24, 0x200); // app[0].size
    for (f[0x200..0x540], 0..) |*b, i| b.* = @truncate(i);
    return f[0..0x540];
}

/// A made-up generic bootloader: 0x100 bytes of code under tag 0xfd.
pub fn fakeBootloader(f: *[0x200]u8) []const u8 {
    @memset(f, 0);
    w32(f, 0, 0x10de);
    w32(f, 12, 0x20);
    w32(f, 16, 0x80);
    w32(f, 20, 0x180);
    w32(f, 0x20 + 0, 0xfd); // start_tag
    w32(f, 0x20 + 8, 0x40); // code_off
    w32(f, 0x20 + 12, 0x100); // code_size
    for (f[0xc0..0x1c0], 0..) |*b, i| b.* = @truncate(i ^ 0x5a);
    return f[0..0x200];
}

var test_model: Model = .{};

test "falcon: a booter's parts, and its signature patched into a copy" {
    var file: [0x600]u8 = undefined;
    const b = try booter(fakeBooter(&file));
    try testing.expectEqual(@as(usize, 0x340), b.image.len);
    try testing.expectEqual(@as(u32, 2), b.sigs);
    try testing.expectEqual(@as(usize, 16), b.sig.len);
    try testing.expectEqual(@as(u8, 0xa0), b.sig[0]);
    try testing.expectEqual(@as(u32, 0x310), b.sig_at);
    try testing.expectEqual(Seg{ .img = 0, .base = 0, .size = 0x100 }, b.nmem);
    try testing.expectEqual(Seg{ .img = 0x100, .base = 0x100, .size = 0x200 }, b.imem);
    try testing.expectEqual(Seg{ .img = 0x300, .base = 0, .size = 0x40 }, b.dmem);
    try testing.expectEqual(@as(u32, 0), b.boot_addr);
    var copy: [0x340]u8 = undefined;
    const img = try b.signed(&copy);
    try testing.expectEqualSlices(u8, b.sig, img[0x310..0x320]);
    try testing.expectEqual(@as(u8, 0x0f), img[0x30f]);
    try testing.expectEqual(@as(u8, 0x20), img[0x320]);
    // (the file itself is as it was)
    try testing.expectEqual(@as(u8, 0x10), b.image[0x310]);
    var short: [0x100]u8 = undefined;
    try testing.expectError(error.Short, b.signed(&short));
    // a file cut short, and one whose application is not whole blocks
    try testing.expectError(error.Short, booter(file[0..0x300]));
    w32(&file, 0xc0 + 24, 0x1f0);
    try testing.expectError(error.BadHeader, booter(file[0..0x540]));
}

test "falcon: the generic bootloader's code and tag; the descriptor it is given" {
    var file: [0x200]u8 = undefined;
    const bl = try bootloader(fakeBootloader(&file));
    try testing.expectEqual(@as(u32, 0xfd), bl.start_tag);
    try testing.expectEqual(@as(u32, 0xfd00), bl.bootAddr());
    try testing.expectEqual(@as(usize, 0x100), bl.code.len);
    try testing.expectEqual(@as(u8, 0x5a), bl.code[0]);
    const d = (BlDesc{
        .code_dma = 0x1_2345_6000,
        .non_sec_code_off = 0,
        .non_sec_code_size = 0x100,
        .sec_code_off = 0x100,
        .sec_code_size = 0x300,
        .data_dma = 0x1_2345_6400,
        .data_size = 0x200,
    }).bytes();
    try testing.expectEqual(@as(usize, 84), d.len);
    try testing.expectEqual(@as(u32, 4), std.mem.readInt(u32, d[32..36], .little));
    try testing.expectEqual(@as(u64, 0x1_2345_6000), std.mem.readInt(u64, d[36..44], .little));
    try testing.expectEqual(@as(u32, 0x300), std.mem.readInt(u32, d[56..60], .little));
    try testing.expectEqual(@as(u64, 0x1_2345_6400), std.mem.readInt(u64, d[64..72], .little));
    try testing.expectEqual(@as(u32, 0x200), std.mem.readInt(u32, d[72..76], .little));
    try testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, d[76..80], .little));
}

test "falcon: a booter loaded by PIO lands where its header says, tagged and marked; then runs to its halt" {
    test_model = .{};
    var io = TestIo{ .m = &test_model };
    var file: [0x600]u8 = undefined;
    const b = try booter(fakeBooter(&file));
    var copy: [0x340]u8 = undefined;
    const img = try b.signed(&copy);
    try testing.expect(reset(&io, 0, 0x1620_00a1));
    try testing.expectEqual(@as(u32, 2), test_model.resets);
    try testing.expectEqual(@as(u32, 0x1620_00a1), test_model.regs[RM / 4]);
    try testing.expectEqual(@as(u32, 0xffff_ffff), test_model.regs[IRQMCLR / 4]);
    loadBooter(&io, 0, &b, img);
    try testing.expectEqual(@as(u32, 0x80), test_model.regs[FBIF_CTL / 4] & 0x80);
    try testing.expectEqualSlices(u8, img[0..0x100], test_model.code[0..0x100]);
    try testing.expectEqualSlices(u8, img[0x100..0x300], test_model.code[0x100..0x300]);
    try testing.expectEqualSlices(u8, img[0x300..0x340], test_model.data[0..0x40]);
    try testing.expectEqual(@as(u16, 0), test_model.tags[0]);
    try testing.expectEqual(@as(u16, 1), test_model.tags[1]);
    try testing.expectEqual(@as(u16, 2), test_model.tags[2]);
    try testing.expect(!test_model.secure[0] and test_model.secure[1] and test_model.secure[2]);
    // (the signature is in the data that was loaded)
    try testing.expectEqualSlices(u8, b.sig, test_model.data[0x10..0x20]);
    const r = run(&io, 0, b.boot_addr, 0x1234_5000, 0x1);
    try testing.expect(r.ok());
    try testing.expectEqual(@as(u32, 1), test_model.starts);
    try testing.expectEqual(@as(u32, 0x1), test_model.regs[MAILBOX1 / 4]);
}

test "falcon: the generic bootloader at the top of code memory, its descriptor in data memory" {
    test_model = .{ .code_limit = 0x8000 };
    var io = TestIo{ .m = &test_model };
    var file: [0x200]u8 = undefined;
    const bl = try bootloader(fakeBootloader(&file));
    const desc = BlDesc{ .code_dma = 0x7000_0000, .non_sec_code_off = 0, .non_sec_code_size = 0x100, .sec_code_off = 0x100, .sec_code_size = 0x300, .data_dma = 0x7000_0400, .data_size = 0x200 };
    try testing.expect(loadWithBootloader(&io, 0, bl, desc));
    try testing.expectEqualSlices(u8, bl.code, test_model.code[0x7f00..0x8000]);
    try testing.expectEqual(@as(u16, 0xfd), test_model.tags[0x7f]);
    try testing.expect(!test_model.secure[0x7f]);
    const want = desc.bytes();
    try testing.expectEqualSlices(u8, &want, test_model.data[0..84]);
    try testing.expectEqual(@as(u32, 5), test_model.regs[(FBIF_TRANSCFG + 16) / 4] & 7);
    // a falcon too small for it
    test_model.code_limit = 0x80;
    try testing.expect(!loadWithBootloader(&io, 0, bl, desc));
}

test "falcon: a scrub that never ends and a microcode that never halts are timeouts, not hangs" {
    test_model = .{ .stuck_scrub = true };
    var io = TestIo{ .m = &test_model };
    try testing.expect(!reset(&io, 0, 0));
    try testing.expect(io.now >= SCRUB_US);
    test_model = .{ .hang = true };
    io = .{ .m = &test_model };
    const r = run(&io, 0, 0, 0, null);
    try testing.expect(!r.halted and !r.ok());
    try testing.expect(io.now >= HALT_US);
    // a microcode that halts with an error in MAILBOX0
    test_model = .{ .on_start = struct {
        fn f(m: *Model) void {
            m.regs[MAILBOX0 / 4] = 0x25;
        }
    }.f };
    io = .{ .m = &test_model };
    const e = run(&io, 0, 0, 0, null);
    try testing.expect(e.halted and !e.ok());
    try testing.expectEqual(@as(u32, 0x25), e.mbox0);
}

test "falcon: started through the alias register when the CPU control is locked" {
    test_model = .{};
    var io = TestIo{ .m = &test_model };
    test_model.regs[CPUCTL / 4] = CPUCTL_ALIAS_EN | CPUCTL_HALTED;
    start(&io, 0);
    try testing.expectEqual(@as(u32, 1), test_model.starts);
    try testing.expect(halted(&io, 0));
    try testing.expect(!riscvActive(&io, 0));
}
