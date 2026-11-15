//! @zpm/nvidia turing — GSP-RM's boot on a Turing GPU (TU10x, TU11x: the
//! RTX 2080 Ti is TU102), the part that differs from Blackwell's: there is
//! no FSP to hand a Chain of Trust to. The driver lays out VRAM's protected
//! top itself and runs two signed microcodes to get GSP-RM started.
//!
//! The order is nouveau's (nvkm/subdev/gsp/tu102.c's tu102_gsp_oneinit,
//! tu102_gsp_init and tu102_gsp_fini, gsp/fwsec.c, rm/r535/gsp.c's CPU
//! sequencer: MIT), checked against NVIDIA's open-gpu-kernel-modules
//! 570.144 (kgspCalculateFbLayout_TU102: MIT), used as documentation only:
//!
//! 1. VRAM's size (0x100ce0) and where the VBIOS keeps its VGA workspace
//!    (0x625f04) give the layout, top down: the workspace, FRTS (1 MiB),
//!    the GSP's bootloader, GSP-RM's image, its heap, the WPR metadata's
//!    megabyte (where WPR2 starts), and a megabyte of unprotected heap
//!    below that (`layout`). The driver writes those offsets into the WPR
//!    metadata (Blackwell's FSP fills them in itself).
//! 2. FWSEC, taken from the card's VBIOS (vbios.sig) and patched with the
//!    FRTS command and FRTS's place, runs on the GSP falcon through the
//!    generic bootloader (`fwsecRun`). It leaves its result in a scratch
//!    register and WPR2's bounds in 0x1fa824/0x1fa828 (`frtsStatus`).
//! 3. The GSP falcon is reset into its RISC-V mode and told where libos's
//!    arguments are (`gspToRiscv`).
//! 4. booter_load runs on the SEC2 falcon with the WPR metadata's address
//!    in its mailboxes (`booterRun`): it checks GSP-RM's image, copies it
//!    into WPR2 and starts it on the GSP. The driver writes the
//!    bootloader's version to the GSP's OS register and GSP-RM's RISC-V
//!    core is then running (`gspStarted`).
//! 5. On its way to GSP_INIT_DONE, GSP-RM asks the driver, through its CPU
//!    sequencer, to reset, start and resume its own core (`coreReset`,
//!    `coreStart`, `coreWaitHalt`, `coreResume`).
//!
//! Unloading (after UNLOADING_GUEST_DRIVER): the GSP falcon reset, FWSEC
//! again with the SB command (`sbStatus`), then booter_unload on SEC2,
//! which takes WPR2 down so the next driver boots its own GSP.
//!
//! Every wait is bounded (falcon.sig). The hardware is reached through
//! `io` (BAR0 for Galaxy's kernel; `GpuModel` in the tests, which stands
//! for the card's two falcons and what the microcodes leave behind).
//! Nothing here has run on a card yet. Allocation-free.

const std = @import("std");
const falcon = @import("falcon.sig");
const vbios = @import("vbios.sig");

// ── Registers (BAR0 offsets) ────────────────────────────────────────────────

pub const PMC_BOOT_0: u32 = 0x000000;
/// NV_PFB_PRI_MMU_LOCAL_MEMORY_RANGE: VRAM's size (nouveau's
/// gp102_fb_vidmem_size; Ampere on has it in 0x1183a4 instead).
pub const VIDMEM_RANGE: u32 = 0x100ce0;
/// NV_PDISP_VGA_WORKSPACE_BASE: where the VBIOS keeps its VGA workspace.
pub const VGA_WORKSPACE: u32 = 0x625f04;
pub const WPR2_LO: u32 = 0x1fa824;
pub const WPR2_HI: u32 = 0x1fa828;
/// NV_PBUS_SW_SCRATCH(0xe): FWSEC-FRTS's error in bits 31:16.
pub const SCRATCH_FRTS: u32 = 0x001400 + 0xe * 4;
/// NV_PBUS_SW_SCRATCH(0x15): FWSEC-SB's error in bits 15:0.
pub const SCRATCH_SB: u32 = 0x001400 + 0x15 * 4;
/// What SEC2 sets (bit 26) when it has resumed GSP-RM for the sequencer.
pub const SEC2_RESUMED: u32 = 0x1180f8;
pub const SEC2_RESUMED_BIT: u32 = 1 << 26;
/// BAR1's page-table register on Turing (nouveau's tu102_bar_bar1_init):
/// bit 31 set puts a page table behind BAR1; clear, BAR1 offsets are VRAM
/// offsets.
pub const BAR1_BLOCK: u32 = 0xb80f40;
pub const BAR1_VIRTUAL: u32 = 1 << 31;

// ── VRAM's layout ───────────────────────────────────────────────────────────

/// VRAM's size from NV_PFB_PRI_MMU_LOCAL_MEMORY_RANGE: a magnitude (bits
/// 9:4) scaled by a power of two of MiB (3:0); with bit 30 (ECC) a
/// sixteenth of it is not the client's.
pub fn vidmemSize(range: u32) u64 {
    const mag: u64 = (range & 0x3f0) >> 4;
    const scale: u6 = @intCast(range & 0xf);
    const size = mag << (scale + 20);
    return if (range & 0x4000_0000 != 0) size / 16 * 15 else size;
}

/// Where the VGA workspace starts, from NV_PDISP_VGA_WORKSPACE_BASE
/// (`reg`; null when the display is not there): the last megabyte unless
/// the register is valid (bit 3) and says higher; one that says lower
/// leaves only the last 128 KiB (nouveau's tu102_gsp_vga_workspace_addr).
pub fn vgaWorkspace(fb_size: u64, reg: ?u32) u64 {
    const base = fb_size - 0x10_0000;
    const v = reg orelse return base;
    if (v & 0x8 == 0) return base;
    const addr = @as(u64, v & 0xffff_ff00) << 8;
    if (addr < base) return fb_size - 0x2_0000;
    return addr;
}

/// GSP-RM's heap in WPR2 for a Turing GPU with `fb_size` of VRAM (libos2:
/// no carve-out; 8 MiB of RM's own, 96 KiB per GiB of VRAM, 96 MiB for
/// client allocations; at least 64 MiB: nouveau's r570_wpr_libos2 and
/// tu102_gsp_wpr_heap_size).
pub fn heapSize(fb_size: u64) u64 {
    const mib: u64 = 1 << 20;
    const gib = (fb_size + (1 << 30) - 1) >> 30;
    const per_gb = ((96 << 10) * gib + mib - 1) / mib * mib;
    const clients = ((48 << 10) * 2048 + mib - 1) / mib * mib;
    return @max((8 << 20) + per_gb + clients, 64 << 20);
}

pub const FRTS_SIZE: u64 = 0x10_0000;
pub const NON_WPR_HEAP: u64 = 0x10_0000;

/// What goes where at the top of VRAM (offsets in VRAM, in bytes).
pub const Layout = struct {
    fb_size: u64,
    vga_addr: u64,
    vga_size: u64,
    /// The end of what the firmware may take (the workspace's start,
    /// rounded down to 128 KiB): the WPR metadata's gspFwWprEnd.
    wpr_end: u64,
    frts_addr: u64,
    frts_size: u64,
    boot_addr: u64,
    boot_size: u64,
    elf_addr: u64,
    elf_size: u64,
    heap_addr: u64,
    heap_size: u64,
    /// WPR2: from the megabyte holding the metadata to FRTS's end.
    wpr2_addr: u64,
    wpr2_size: u64,
    nonwpr_addr: u64,
    nonwpr_size: u64,

    /// The lowest VRAM offset the firmware takes: what is below it is the
    /// client's (GSP-RM's static information says so again, by regions).
    pub fn low(l: Layout) u64 {
        return l.nonwpr_addr;
    }
};

fn down(v: u64, a: u64) u64 {
    return v / a * a;
}

/// The layout for `fb_size` of VRAM with the VGA workspace at `vga_addr`,
/// a GSP bootloader of `boot_bytes`, GSP-RM's image of `elf_bytes` and
/// WPR metadata of `meta_bytes` (tu102_gsp_oneinit). Null when it does not
/// fit (a VRAM smaller than the firmware: not a card this boots).
pub fn layout(fb_size: u64, vga_addr: u64, boot_bytes: u64, elf_bytes: u64, meta_bytes: u64) ?Layout {
    if (vga_addr == 0 or vga_addr > fb_size) return null;
    const heap = heapSize(fb_size);
    const wpr_end = down(vga_addr, 0x2_0000);
    if (wpr_end < FRTS_SIZE + boot_bytes + elf_bytes + heap + meta_bytes + 0x40_0000) return null;
    var l: Layout = undefined;
    l.fb_size = fb_size;
    l.vga_addr = vga_addr;
    l.vga_size = fb_size - vga_addr;
    l.wpr_end = wpr_end;
    l.frts_size = FRTS_SIZE;
    l.frts_addr = wpr_end - FRTS_SIZE;
    l.boot_size = boot_bytes;
    l.boot_addr = down(l.frts_addr - boot_bytes, 0x1000);
    l.elf_size = elf_bytes;
    l.elf_addr = down(l.boot_addr - elf_bytes, 0x1_0000);
    l.heap_addr = down(l.elf_addr - heap, 0x10_0000);
    l.heap_size = down(l.elf_addr - l.heap_addr, 0x10_0000);
    l.wpr2_addr = down(l.heap_addr - meta_bytes, 0x10_0000);
    l.wpr2_size = l.frts_addr + l.frts_size - l.wpr2_addr;
    l.nonwpr_size = NON_WPR_HEAP;
    l.nonwpr_addr = l.wpr2_addr - NON_WPR_HEAP;
    return l;
}

// ── FWSEC on the GSP falcon ─────────────────────────────────────────────────

/// How a microcode's run went, step by step (each false one is where it
/// stopped).
pub const Step = struct {
    /// The falcon reset and its memory scrubbed.
    reset: bool = false,
    /// The microcode (or its bootloader) loaded.
    loaded: bool = false,
    /// How it ran (only when loaded).
    run: falcon.Run = .{ .halted = false, .mbox0 = 0, .mbox1 = 0 },

    pub fn ok(s: Step) bool {
        return s.reset and s.loaded and s.run.ok();
    }
};

/// FWSEC (its patched image at `image_pa` in system memory, as `f` lays it
/// out) run on the GSP falcon through the generic bootloader `bl`, to its
/// halt (nouveau's nvkm_gsp_fwsec_boot with tu102_gsp_fwsec).
pub fn fwsecRun(io: anytype, bl: falcon.Bootloader, f: *const vbios.Fwsec, image_pa: u64, boot0: u32) Step {
    var s = Step{};
    s.reset = falcon.reset(io, falcon.GSP, boot0);
    if (!s.reset) return s;
    s.loaded = falcon.loadWithBootloader(io, falcon.GSP, bl, .{
        .code_dma = image_pa,
        .non_sec_code_off = f.imem_phys_base,
        .non_sec_code_size = f.imem_load_size - f.imem_sec_size,
        .sec_code_off = f.imem_sec_base,
        .sec_code_size = f.imem_sec_size,
        .data_dma = image_pa + f.dmem_offset,
        .data_size = f.dmem_load_size,
    });
    if (!s.loaded) return s;
    s.run = falcon.run(io, falcon.GSP, bl.bootAddr(), 0, null);
    return s;
}

/// What FWSEC-FRTS left: its error (0: none) and WPR2's bounds.
pub const Frts = struct {
    err: u32,
    wpr2_lo: u32,
    wpr2_hi: u32,

    /// No error, and WPR2 is up.
    pub fn ok(f: Frts) bool {
        return f.err == 0 and f.wpr2_hi != 0;
    }
};

pub fn frtsStatus(io: anytype) Frts {
    return .{ .err = io.rd(SCRATCH_FRTS) >> 16, .wpr2_lo = io.rd(WPR2_LO), .wpr2_hi = io.rd(WPR2_HI) };
}

/// FWSEC-SB's error (0: none).
pub fn sbStatus(io: anytype) u32 {
    return io.rd(SCRATCH_SB) & 0xffff;
}

/// WPR2 is up (a GSP's region is set: FWSEC-FRTS ran since the last cold
/// boot, or a driver left its GSP running).
pub fn wpr2Up(io: anytype) bool {
    return io.rd(WPR2_HI) != 0;
}

// ── The booter on SEC2, and the GSP's start ─────────────────────────────────

/// A booter's signed `image` run on the SEC2 falcon with `mbox0`/`mbox1`
/// (the WPR metadata's address for booter_load; 0xff, 0xff for
/// booter_unload), to its halt (tu102_gsp_booter_load, _unload).
pub fn booterRun(io: anytype, b: *const falcon.Booter, image: []const u8, mbox0: u32, mbox1: u32, boot0: u32) Step {
    var s = Step{};
    s.reset = falcon.reset(io, falcon.SEC2_TURING, boot0);
    if (!s.reset) return s;
    falcon.loadBooter(io, falcon.SEC2_TURING, b, image);
    s.loaded = true;
    s.run = falcon.run(io, falcon.SEC2_TURING, b.boot_addr, mbox0, mbox1);
    return s;
}

/// The GSP falcon reset into its RISC-V mode, and told where libos's
/// arguments are (the end of tu102_gsp_oneinit). False when the reset's
/// memory scrub did not finish.
pub fn gspToRiscv(io: anytype, libos_pa: u64) bool {
    if (!falcon.resetEngine(io, falcon.GSP)) return false;
    io.wr(falcon.GSP + falcon.MAILBOX0, @truncate(libos_pa));
    io.wr(falcon.GSP + falcon.MAILBOX1, @truncate(libos_pa >> 32));
    return true;
}

/// After booter_load: the bootloader's version in the GSP's OS register;
/// true when GSP-RM's RISC-V core is running (r535_gsp_init's first lines).
pub fn gspStarted(io: anytype, app_version: u32) bool {
    io.wr(falcon.GSP + falcon.OS, app_version);
    return falcon.riscvActive(io, falcon.GSP);
}

// ── GSP-RM's CPU sequencer: its core's steps ────────────────────────────────

/// CORE_RESET: the GSP falcon reset, its DMA set for no context.
pub fn coreReset(io: anytype, boot0: u32) bool {
    if (!falcon.reset(io, falcon.GSP, boot0)) return false;
    falcon.noContext(io, falcon.GSP);
    return true;
}

/// CORE_START: the GSP falcon started where it stands.
pub fn coreStart(io: anytype) void {
    falcon.start(io, falcon.GSP);
}

/// CORE_WAIT_FOR_HALT (2 s; the sequencer goes on either way, as nouveau's).
pub fn coreWaitHalt(io: anytype) bool {
    return falcon.waitHalt(io, falcon.GSP);
}

/// How CORE_RESUME went.
pub const Resume = struct {
    reset: bool = false,
    /// SEC2 said it resumed GSP-RM within 2 s.
    resumed: bool = false,
    sec2_mbox0: u32 = 0,
    riscv: bool = false,

    pub fn ok(r: Resume) bool {
        return r.reset and r.resumed and r.sec2_mbox0 == 0 and r.riscv;
    }
};

/// CORE_RESUME: the GSP falcon reset into RISC-V mode with libos's
/// arguments, SEC2 started again (the booter resumes GSP-RM), SEC2's word
/// that it did, the bootloader's version, and the RISC-V core running.
pub fn coreResume(io: anytype, libos_pa: u64, app_version: u32) Resume {
    var r = Resume{};
    r.reset = gspToRiscv(io, libos_pa);
    if (!r.reset) return r;
    falcon.start(io, falcon.SEC2_TURING);
    const end = io.nowUs() + falcon.HALT_US;
    while (true) {
        r.resumed = io.rd(SEC2_RESUMED) & SEC2_RESUMED_BIT != 0;
        if (r.resumed or io.nowUs() >= end) break;
        io.pause();
    }
    if (!r.resumed) r.resumed = io.rd(SEC2_RESUMED) & SEC2_RESUMED_BIT != 0;
    if (!r.resumed) return r;
    r.sec2_mbox0 = io.rd(falcon.SEC2_TURING + falcon.MAILBOX0);
    if (r.sec2_mbox0 != 0) return r;
    r.riscv = gspStarted(io, app_version);
    return r;
}

// ── A Turing GPU for the tests ──────────────────────────────────────────────

/// The registers a Turing boot touches, with the two falcons behind them
/// and the microcodes' effects: FWSEC (read through the bootloader's
/// descriptor from `mem`, the system memory the test handed it) brings
/// WPR2 up for FRTS, or answers SB; booter_load (the image whose first
/// data word is `load_mark`) starts GSP-RM's RISC-V core when WPR2 is up
/// and its mailboxes name `meta_pa`; booter_unload takes WPR2 down. What
/// ran is counted. Keep it static (two falcons' memories).
pub const GpuModel = struct {
    gsp: falcon.Model = .{},
    sec2: falcon.Model = .{},
    boot0: u32 = 0x1620_00a1,
    /// 11 GiB: the RTX 2080 Ti's.
    vidmem_range: u32 = 0xba,
    vga_workspace: u32 = 0,
    wpr2_lo: u32 = 0,
    wpr2_hi: u32 = 0,
    scratch_frts: u32 = 0,
    scratch_sb: u32 = 0,
    resumed: u32 = 0,
    bar1_block: u32 = 0,
    now: u64 = 0,
    /// System memory the falcons fetch from (FWSEC's patched image).
    mem_pa: u64 = 0,
    mem: []const u8 = &.{},
    /// FWSEC as the VBIOS lays it out (to find its command).
    fwsec: ?vbios.Fwsec = null,
    meta_pa: u64 = 0,
    load_mark: u32 = 0,
    unload_mark: u32 = 0,
    frts_runs: u32 = 0,
    sb_runs: u32 = 0,
    loads: u32 = 0,
    unloads: u32 = 0,
    resumes: u32 = 0,
    /// The FRTS region FWSEC was given (VRAM bytes).
    frts_addr: u64 = 0,
    frts_size: u64 = 0,
    /// Make FWSEC-FRTS report this error.
    frts_error: u32 = 0,
    /// Make booter_load halt with this in MAILBOX0.
    load_error: u32 = 0,
    /// SEC2's resets at its last start, and whether that was booter_load
    /// doing its work (what a start without a reset resumes).
    sec2_resets: u32 = 0,
    load_ok: bool = false,

    pub fn init(g: *GpuModel) void {
        g.gsp.on_start = gspMicrocode;
        g.gsp.ctx = g;
        g.sec2.on_start = sec2Microcode;
        g.sec2.ctx = g;
    }

    fn falconOf(g: *GpuModel, addr: u32) ?struct { m: *falcon.Model, reg: u32 } {
        if (addr >= falcon.GSP and addr < falcon.GSP + 0x2000) return .{ .m = &g.gsp, .reg = addr - falcon.GSP };
        if (addr >= falcon.SEC2_TURING and addr < falcon.SEC2_TURING + 0x2000) return .{ .m = &g.sec2, .reg = addr - falcon.SEC2_TURING };
        return null;
    }

    pub fn rd(g: *GpuModel, addr: u32) u32 {
        if (g.falconOf(addr)) |f| return f.m.rd(f.reg);
        return switch (addr) {
            PMC_BOOT_0 => g.boot0,
            VIDMEM_RANGE => g.vidmem_range,
            VGA_WORKSPACE => g.vga_workspace,
            WPR2_LO => g.wpr2_lo,
            WPR2_HI => g.wpr2_hi,
            SCRATCH_FRTS => g.scratch_frts,
            SCRATCH_SB => g.scratch_sb,
            SEC2_RESUMED => g.resumed,
            BAR1_BLOCK => g.bar1_block,
            else => 0xbadf_1100,
        };
    }

    pub fn wr(g: *GpuModel, addr: u32, v: u32) void {
        if (g.falconOf(addr)) |f| return f.m.wr(f.reg, v);
        if (addr == BAR1_BLOCK) g.bar1_block = v;
    }

    pub fn nowUs(g: *GpuModel) u64 {
        return g.now;
    }

    pub fn pause(g: *GpuModel) void {
        g.now += 10;
    }

    fn sys(g: *GpuModel, pa: u64, len: usize) ?[]const u8 {
        if (pa < g.mem_pa or pa - g.mem_pa + len > g.mem.len) return null;
        return g.mem[@intCast(pa - g.mem_pa)..][0..len];
    }

    /// The GSP falcon's microcode: FWSEC, when the generic bootloader is
    /// at the top of code memory and its descriptor names an image.
    fn gspMicrocode(m: *falcon.Model) void {
        const g: *GpuModel = @ptrCast(@alignCast(m.ctx.?));
        m.regs[falcon.MAILBOX0 / 4] = 0xbad0_0001;
        const f = g.fwsec orelse return;
        // (the descriptor: ctx_dma at 32, code at 36, data at 64, its size at 72)
        if (std.mem.readInt(u32, m.data[32..36], .little) != falcon.DMAIDX_PHYS_SYS_NCOH) return;
        if (m.regs[(falcon.FBIF_TRANSCFG + 16) / 4] & 7 != 5 or m.regs[falcon.FBIF_CTL / 4] & 0x80 == 0) return;
        const data_pa = std.mem.readInt(u64, m.data[64..72], .little);
        const data_len = std.mem.readInt(u32, m.data[72..76], .little);
        if (data_len != f.dmem_load_size) return;
        const d = g.sys(data_pa, data_len) orelse return;
        // (the command interface, as vbios.patch writes it: the mapper
        // is its application 4)
        const hdr: usize = f.interface_offset;
        var map: usize = 0;
        var i: usize = 0;
        while (i < d[hdr + 3]) : (i += 1) {
            const app = hdr + d[hdr + 1] + i * @as(usize, d[hdr + 2]);
            if (std.mem.readInt(u32, d[app..][0..4], .little) == 4) map = std.mem.readInt(u32, d[app + 4 ..][0..4], .little);
        }
        if (map == 0) return;
        const cmd = std.mem.readInt(u32, d[map + 44 ..][0..4], .little);
        const in: usize = std.mem.readInt(u32, d[map + 8 ..][0..4], .little);
        switch (cmd) {
            vbios.CMD_FRTS => {
                g.frts_runs += 1;
                g.frts_addr = @as(u64, std.mem.readInt(u32, d[in + 32 ..][0..4], .little)) << 12;
                g.frts_size = @as(u64, std.mem.readInt(u32, d[in + 36 ..][0..4], .little)) << 12;
                g.scratch_frts = g.frts_error << 16;
                if (g.frts_error == 0) {
                    g.wpr2_lo = @intCast((g.frts_addr >> 12) << 4);
                    g.wpr2_hi = @intCast(((g.frts_addr + g.frts_size - 1) >> 12) << 4);
                }
            },
            vbios.CMD_SB => {
                g.sb_runs += 1;
                g.scratch_sb = 0;
            },
            else => return,
        }
        m.regs[falcon.MAILBOX0 / 4] = 0;
    }

    /// SEC2's: a booter by its first data word; started again without a
    /// load (the sequencer's resume), it resumes GSP-RM.
    fn sec2Microcode(m: *falcon.Model) void {
        const g: *GpuModel = @ptrCast(@alignCast(m.ctx.?));
        const mark = std.mem.readInt(u32, m.data[0..4], .little);
        const mbox = @as(u64, m.regs[falcon.MAILBOX1 / 4]) << 32 | m.regs[falcon.MAILBOX0 / 4];
        const fresh = m.resets != g.sec2_resets;
        g.sec2_resets = m.resets;
        if (!fresh) {
            if (!g.load_ok) {
                m.regs[falcon.MAILBOX0 / 4] = 0xbad0_0004;
                return;
            }
            g.resumes += 1;
            g.resumed |= SEC2_RESUMED_BIT;
            g.gsp.riscv = true;
            m.regs[falcon.MAILBOX0 / 4] = 0;
            return;
        }
        g.load_ok = false;
        if (mark == g.load_mark) {
            g.loads += 1;
            if (g.load_error != 0 or g.wpr2_hi == 0 or mbox != g.meta_pa) {
                m.regs[falcon.MAILBOX0 / 4] = if (g.load_error != 0) g.load_error else 0xbad0_0002;
                return;
            }
            g.load_ok = true;
            g.gsp.riscv = true;
            m.regs[falcon.MAILBOX0 / 4] = 0;
        } else if (mark == g.unload_mark) {
            g.unloads += 1;
            g.wpr2_lo = 0;
            g.wpr2_hi = 0;
            g.gsp.riscv = false;
            m.regs[falcon.MAILBOX0 / 4] = 0;
        } else m.regs[falcon.MAILBOX0 / 4] = 0xbad0_0003;
    }
};

// ── Host tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

test "turing: VRAM's size and the VGA workspace as nouveau reads them" {
    // 11 GiB: magnitude 11, scale 10 (MiB << 10)
    try testing.expectEqual(@as(u64, 11 << 30), vidmemSize(0xba));
    try testing.expectEqual(@as(u64, 8 << 30), vidmemSize(0x1 << 4 | 13));
    // (ECC: fifteen sixteenths)
    try testing.expectEqual(@as(u64, 15 << 30), vidmemSize(0x4000_0000 | (0x1 << 4) | 14));
    const fb: u64 = 11 << 30;
    try testing.expectEqual(fb - 0x10_0000, vgaWorkspace(fb, null));
    try testing.expectEqual(fb - 0x10_0000, vgaWorkspace(fb, 0)); // (not valid)
    // valid, in the last megabyte: taken ((fb - 0x80000) >> 8, bit 3)
    const inside: u32 = @intCast(((fb - 0x8_0000) >> 8) | 0x8);
    try testing.expectEqual(fb - 0x8_0000, vgaWorkspace(fb, inside));
    // valid but lower than the last megabyte: only the last 128 KiB
    const low: u32 = @intCast(((fb - 0x40_0000) >> 8) | 0x8);
    try testing.expectEqual(fb - 0x2_0000, vgaWorkspace(fb, low));
}

test "turing: the RTX 2080 Ti's layout (11 GiB), as nouveau's tu102_gsp_oneinit computes it" {
    const fb: u64 = 11 << 30;
    // 8 + ALIGN(96 KiB * 11, 1 MiB) = 2 + 96 MiB
    try testing.expectEqual(@as(u64, 106 << 20), heapSize(fb));
    try testing.expectEqual(@as(u64, 105 << 20), heapSize(4 << 30));
    const l = layout(fb, vgaWorkspace(fb, null), 0x1_2345, 0x3ff_0123, 256).?;
    try testing.expectEqual(@as(u64, 0x2_bff0_0000), l.vga_addr);
    try testing.expectEqual(@as(u64, 0x10_0000), l.vga_size);
    try testing.expectEqual(@as(u64, 0x2_bff0_0000), l.wpr_end);
    try testing.expectEqual(@as(u64, 0x2_bfe0_0000), l.frts_addr);
    try testing.expectEqual(@as(u64, 0x2_bfde_d000), l.boot_addr); // (0x2bfe00000 - 0x12345, down to 4 KiB)
    try testing.expectEqual(@as(u64, 0x2_bbdf_0000), l.elf_addr); // (boot - 0x3ff0123, down to 64 KiB)
    try testing.expectEqual(@as(u64, 0x2_b530_0000), l.heap_addr); // (elf - 106 MiB, down to 1 MiB)
    try testing.expectEqual(@as(u64, 0x6a0_0000), l.heap_size);
    try testing.expectEqual(@as(u64, 0x2_b520_0000), l.wpr2_addr);
    try testing.expectEqual(l.frts_addr + l.frts_size - l.wpr2_addr, l.wpr2_size);
    try testing.expectEqual(@as(u64, 0x2_b510_0000), l.nonwpr_addr);
    try testing.expectEqual(l.nonwpr_addr, l.low());
    // every part inside VRAM, in order, none overlapping
    try testing.expect(l.nonwpr_addr + l.nonwpr_size == l.wpr2_addr);
    try testing.expect(l.wpr2_addr + 256 <= l.heap_addr);
    try testing.expect(l.heap_addr + l.heap_size <= l.elf_addr);
    try testing.expect(l.elf_addr + l.elf_size <= l.boot_addr);
    try testing.expect(l.boot_addr + l.boot_size <= l.frts_addr);
    try testing.expect(l.frts_addr + l.frts_size == l.wpr_end);
    // a VRAM too small for the firmware
    try testing.expect(layout(64 << 20, (64 << 20) - 0x10_0000, 0x1000, 0x400_0000, 256) == null);
}

var gpu: GpuModel = .{};

const Fixture = struct {
    rom: vbios.TestRom = undefined,
    image: [0x600]u8 align(8) = undefined,
    bl_file: [0x200]u8 = undefined,
    load_file: [0x600]u8 = undefined,
    unload_file: [0x600]u8 = undefined,
    load_image: [0x340]u8 = undefined,
    unload_image: [0x340]u8 = undefined,
};
var fx: Fixture = .{};

test "turing: the whole SEC2 boot against the model, then the unload" {
    gpu = .{};
    gpu.init();
    const boot0 = gpu.rd(PMC_BOOT_0);
    const fb = vidmemSize(gpu.rd(VIDMEM_RANGE));
    const l = layout(fb, vgaWorkspace(fb, gpu.rd(VGA_WORKSPACE)), 0x8000, 0x200_0000, 256).?;

    // FWSEC from the VBIOS, patched for FRTS in a copy in "system memory"
    fx.rom.build(2);
    const rom = try vbios.open(&fx.rom.bytes);
    const f = try vbios.fwsec(&rom);
    @memcpy(&fx.image, f.image(&rom));
    try vbios.patch(&fx.image, &f, vbios.CMD_FRTS, l.frts_addr, l.frts_size);
    const image_pa: u64 = 0x7654_0000;
    gpu.mem_pa = image_pa;
    gpu.mem = &fx.image;
    gpu.fwsec = f;
    const bl = try falcon.bootloader(falcon.fakeBootloader(&fx.bl_file));

    try testing.expect(!wpr2Up(&gpu));
    const s = fwsecRun(&gpu, bl, &f, image_pa, boot0);
    try testing.expect(s.ok());
    try testing.expectEqual(@as(u32, 1), gpu.frts_runs);
    try testing.expectEqual(l.frts_addr, gpu.frts_addr);
    try testing.expectEqual(l.frts_size, gpu.frts_size);
    const fr = frtsStatus(&gpu);
    try testing.expect(fr.ok());
    try testing.expect(wpr2Up(&gpu));

    // the GSP falcon into RISC-V mode with libos's arguments
    const libos_pa: u64 = 0x1_2222_3000;
    try testing.expect(gspToRiscv(&gpu, libos_pa));
    try testing.expectEqual(@as(u32, 0x2222_3000), gpu.gsp.regs[falcon.MAILBOX0 / 4]);
    try testing.expectEqual(@as(u32, 1), gpu.gsp.regs[falcon.MAILBOX1 / 4]);

    // booter_load on SEC2 with the WPR metadata's address
    const load = try falcon.booter(falcon.fakeBooter(&fx.load_file));
    const load_img = try load.signed(&fx.load_image);
    gpu.load_mark = std.mem.readInt(u32, load_img[load.dmem.img..][0..4], .little);
    gpu.meta_pa = 0x1_0000_4000;
    const b = booterRun(&gpu, &load, load_img, @truncate(gpu.meta_pa), @truncate(gpu.meta_pa >> 32), boot0);
    try testing.expect(b.ok());
    try testing.expectEqual(@as(u32, 1), gpu.loads);
    try testing.expect(gspStarted(&gpu, 0x0570_0144));
    try testing.expectEqual(@as(u32, 0x0570_0144), gpu.gsp.regs[falcon.OS / 4]);

    // GSP-RM's sequencer: reset, start, wait, resume
    try testing.expect(coreReset(&gpu, boot0));
    try testing.expect(!falcon.riscvActive(&gpu, falcon.GSP));
    coreStart(&gpu);
    try testing.expect(coreWaitHalt(&gpu));
    const r = coreResume(&gpu, libos_pa, 0x0570_0144);
    try testing.expect(r.ok());
    try testing.expectEqual(@as(u32, 1), gpu.resumes);

    // unload: the GSP falcon reset, FWSEC-SB, booter_unload: WPR2 down
    try testing.expect(falcon.reset(&gpu, falcon.GSP, boot0));
    @memcpy(&fx.image, f.image(&rom));
    try vbios.patch(&fx.image, &f, vbios.CMD_SB, 0, 0);
    try testing.expect(fwsecRun(&gpu, bl, &f, image_pa, boot0).ok());
    try testing.expectEqual(@as(u32, 1), gpu.sb_runs);
    try testing.expectEqual(@as(u32, 0), sbStatus(&gpu));
    _ = falcon.fakeBooter(&fx.unload_file);
    // (another booter: its first data word differs)
    std.mem.writeInt(u32, fx.unload_file[0x200 + 0x300 ..][0..4], 0x0bad_cafe, .little);
    const unload = try falcon.booter(fx.unload_file[0..0x540]);
    const unload_img = try unload.signed(&fx.unload_image);
    gpu.unload_mark = 0x0bad_cafe;
    try testing.expect(booterRun(&gpu, &unload, unload_img, 0xff, 0xff, boot0).ok());
    try testing.expectEqual(@as(u32, 1), gpu.unloads);
    try testing.expect(!wpr2Up(&gpu));
}

test "turing: each failure stops at its own step" {
    gpu = .{};
    gpu.init();
    fx.rom.build(2);
    const rom = try vbios.open(&fx.rom.bytes);
    const f = try vbios.fwsec(&rom);
    @memcpy(&fx.image, f.image(&rom));
    try vbios.patch(&fx.image, &f, vbios.CMD_FRTS, 0x2_bfe0_0000, 0x10_0000);
    gpu.mem_pa = 0x7654_0000;
    gpu.mem = &fx.image;
    gpu.fwsec = f;
    const bl = try falcon.bootloader(falcon.fakeBootloader(&fx.bl_file));
    // FWSEC reports an error: it halts clean, the scratch register says
    gpu.frts_error = 0x12;
    try testing.expect(fwsecRun(&gpu, bl, &f, gpu.mem_pa, 0).ok());
    const fr = frtsStatus(&gpu);
    try testing.expectEqual(@as(u32, 0x12), fr.err);
    try testing.expect(!fr.ok());
    // an image the falcon cannot reach (a wrong address): MAILBOX0 is not 0
    gpu.frts_error = 0;
    const bad = fwsecRun(&gpu, bl, &f, 0x1000, 0);
    try testing.expect(bad.reset and bad.loaded and bad.run.halted and !bad.ok());
    // a scrub that never ends: stops at the reset
    gpu.gsp.stuck_scrub = true;
    const stuck = fwsecRun(&gpu, bl, &f, gpu.mem_pa, 0);
    try testing.expect(!stuck.reset and !stuck.loaded);
    try testing.expect(!gspToRiscv(&gpu, 0x1000));
    gpu.gsp.stuck_scrub = false;
    // booter_load without WPR2: its own error
    const load = try falcon.booter(falcon.fakeBooter(&fx.load_file));
    const img = try load.signed(&fx.load_image);
    gpu.load_mark = std.mem.readInt(u32, img[load.dmem.img..][0..4], .little);
    const b = booterRun(&gpu, &load, img, 0, 0, 0);
    try testing.expect(b.reset and b.loaded and b.run.halted and !b.ok());
    try testing.expectEqual(@as(u32, 0xbad0_0002), b.run.mbox0);
    try testing.expect(!gspStarted(&gpu, 1));
    // a resume SEC2 never answers
    const r = coreResume(&gpu, 0x1000, 1);
    try testing.expect(r.reset and !r.resumed and !r.ok());
}
