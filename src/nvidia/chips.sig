//! @zpm/nvidia chips — the NVIDIA GPUs Galaxy's driver knows, and what
//! differs between them: how GSP-RM is booted, which firmware files, the
//! page-table format, the engine classes, the shader model its SMs run and
//! a handful of registers.
//!
//! Two families:
//!
//! - **Blackwell** (GB20x, the RTX 50 series): the Legion 5's RTX 5070
//!   Laptop GPU (GB206) ran everything here. GSP-RM boots through the FSP
//!   (a Chain of Trust message); MMU version 3; sm_120.
//! - **Turing** (TU10x, the RTX 20 series; TU11x, the GTX 16 series): GSP-RM
//!   boots through SEC2 (FWSEC-FRTS from the card's VBIOS on the GSP falcon,
//!   then the booter on the SEC2 falcon: turing.sig, falcon.sig, vbios.sig);
//!   MMU version 2; sm_75. Written for the RTX 2080 Ti (TU102, PCI
//!   10de:1e07) from documentation; nothing of it has run on a card yet.
//!   TU104, TU106, TU116 and TU117 take the same path in nouveau with their
//!   own booter files (linux-firmware's nvidia/tu104/gsp/ and so on; gsp
//!   and bootloader are links to tu102's): they are listed, and untried.
//!
//! What is not here: Ampere and Ada (they boot through SEC2 too, but with
//! the version 3 FWSEC descriptor, its signatures chosen by fuses, and
//! libos3), Hopper, and Volta and older (no GSP-RM firmware for them).
//!
//! The numbers are nouveau's (nvkm/engine/device/base.c's chipsets,
//! nvkm/subdev/gsp/rm/tu1xx.c's and gb20x.c's classes, gsp/tu102.c: MIT)
//! and NVIDIA's open-gpu-kernel-modules 570.144 (MIT), used as
//! documentation only.
//!
//! Allocation-free: a table of constants.

const std = @import("std");

pub const Family = enum { turing, blackwell };

/// How GSP-RM is booted.
pub const Boot = enum {
    /// Turing: FWSEC-FRTS on the GSP falcon, the booter on SEC2.
    sec2,
    /// Blackwell: a Chain of Trust message to the FSP.
    fsp,
};

/// The GPU's page-table format (nouveau's vmmgp100.c, vmmgh100.c).
pub const Mmu = enum { v2, v3 };

/// The shader model the SMs run (zpm's kernel targets).
pub const Sm = enum {
    // (sm_120 first: it is the value of zeroed memory, so an emulator or
    // assembler Work a caller left `undefined` in .bss, as Galaxy's kernel
    // does, is the Legion's unless it is told otherwise)
    sm_120,
    sm_75,

    /// The QMD's SASS_VERSION for it: ((sm >> 4) & 0xf0) | (sm & 0xf) of
    /// GSP-RM's SM version (0x705 on Turing, 0xa04 on GB20x), until GR's
    /// information says.
    pub fn sass(s: Sm) u32 {
        return switch (s) {
            .sm_75 => 0x75,
            .sm_120 => 0xa4,
        };
    }

    pub fn name(s: Sm) []const u8 {
        return switch (s) {
            .sm_75 => "sm_75",
            .sm_120 => "sm_120",
        };
    }
};

/// The engine classes GSP-RM takes for a chip.
pub const Classes = struct {
    usermode: u32,
    channel: u32,
    compute: u32,
    threed: u32,
    copy: u32,
    nvdec: u32,
    nvenc: u32,
};

pub const TURING_CLASSES = Classes{
    .usermode = 0xc461, // TURING_USERMODE_A
    .channel = 0xc46f, // TURING_CHANNEL_GPFIFO_A
    .compute = 0xc5c0, // TURING_COMPUTE_A
    .threed = 0xc597, // TURING_A
    .copy = 0xc5b5, // TURING_DMA_COPY_A
    .nvdec = 0xc4b0, // NVC4B0_VIDEO_DECODER
    .nvenc = 0xc4b7, // NVC4B7_VIDEO_ENCODER
};

pub const BLACKWELL_CLASSES = Classes{
    .usermode = 0xc761, // BLACKWELL_USERMODE_A
    .channel = 0xca6f, // BLACKWELL_CHANNEL_GPFIFO_B
    .compute = 0xcec0, // BLACKWELL_COMPUTE_B
    .threed = 0xce97, // BLACKWELL_B
    .copy = 0xcab5, // BLACKWELL_DMA_COPY_B
    .nvdec = 0xcfb0, // NVCFB0_VIDEO_DECODER
    .nvenc = 0xcfb7, // NVCFB7_VIDEO_ENCODER
};

pub const Chip = struct {
    /// NVIDIA's name for the chip (TU102, GB206).
    name: []const u8,
    /// PMC_BOOT_0 bits 28:20 (nouveau's chipset number: 0x162, 0x1b6).
    chipset: u32,
    family: Family,
    boot: Boot,
    mmu: Mmu,
    sm: Sm,
    classes: Classes,
    /// linux-firmware's directory for its GSP files (nvidia/<fw>/gsp/), and
    /// the one its shared files really live in (a FIRMWARE.TAR may hold
    /// either).
    fw: []const u8,
    fw_shared: []const u8,
    /// GSP-RM's signature section in gsp-570.144.bin for this family.
    sig_section: []const u8,
    /// Where BAR0 mirrors the function's PCI configuration space
    /// (GspSystemInfo's pciConfigMirrorBase; 0x1000 bytes).
    cfg_mirror: u32,
    /// Bit 30 of the doorbell's token (nouveau's gb202_chan_doorbell_handle;
    /// Turing's is runlist << 16 | chid alone).
    token_bit30: bool,
    /// Whether anything of Galaxy's has run on this chip.
    proven: bool,
    /// SM counts for the emulated twin, and for local memory before
    /// GSP-RM's GR information says (a real card's come from it): GPCs,
    /// TPCs a GPC, SMs a TPC, warps an SM. The family's proven or target
    /// chip's design (TU102, GB206) stands in for its siblings.
    gpcs: u32,
    tpcs_per_gpc: u32,
    sms_per_tpc: u32,
    warps_per_sm: u32,
};

fn turing(comptime name: []const u8, chipset: u32, comptime fw: []const u8) Chip {
    return .{
        .name = name,
        .chipset = chipset,
        .family = .turing,
        .boot = .sec2,
        .mmu = .v2,
        .sm = .sm_75,
        .classes = TURING_CLASSES,
        .fw = fw,
        .fw_shared = "tu102",
        .sig_section = ".fwsignature_tu10x",
        .cfg_mirror = 0x088000,
        .token_bit30 = false,
        .proven = false,
        // (TU102's design: 6 GPCs of 6 TPCs, 72 SMs of 32 warps; the RTX
        // 2080 Ti ships 68 of them)
        .gpcs = 6,
        .tpcs_per_gpc = 6,
        .sms_per_tpc = 2,
        .warps_per_sm = 32,
    };
}

fn blackwell(comptime name: []const u8, chipset: u32, comptime fw: []const u8, proven: bool) Chip {
    return .{
        .name = name,
        .chipset = chipset,
        .family = .blackwell,
        .boot = .fsp,
        .mmu = .v3,
        .sm = .sm_120,
        .classes = BLACKWELL_CLASSES,
        .fw = fw,
        .fw_shared = "gb202",
        .sig_section = ".fwsignature_gb20x",
        .cfg_mirror = 0x092000,
        .token_bit30 = true,
        .proven = proven,
        // (GB206's, as GSP-RM told the Legion: 3 GPCs of 8 TPCs, 48 warps)
        .gpcs = 3,
        .tpcs_per_gpc = 8,
        .sms_per_tpc = 2,
        .warps_per_sm = 48,
    };
}

/// The chips, by nouveau's chipset number.
pub const CHIPS = [_]Chip{
    turing("TU102", 0x162, "tu102"),
    turing("TU104", 0x164, "tu104"),
    turing("TU106", 0x166, "tu106"),
    turing("TU117", 0x167, "tu117"),
    turing("TU116", 0x168, "tu116"),
    blackwell("GB202", 0x1b2, "gb202", false),
    blackwell("GB203", 0x1b3, "gb203", false),
    blackwell("GB205", 0x1b5, "gb205", false),
    blackwell("GB206", 0x1b6, "gb206", true),
    blackwell("GB207", 0x1b7, "gb207", false),
};

pub const TU102 = &CHIPS[0];
pub const GB206 = &CHIPS[8];

/// PMC_BOOT_0's chipset number (bits 28:20) and revision (7:0).
pub fn chipsetOf(boot0: u32) u32 {
    return (boot0 & 0x1ff0_0000) >> 20;
}

/// The chip PMC_BOOT_0 names, when Galaxy knows it.
pub fn of(boot0: u32) ?*const Chip {
    return byChipset(chipsetOf(boot0));
}

pub fn byChipset(chipset: u32) ?*const Chip {
    for (&CHIPS) |*c| {
        if (c.chipset == chipset) return c;
    }
    return null;
}

/// A chip by its name, any case ("tu102": NV.TXT's `emulate tu102`).
pub fn byName(name: []const u8) ?*const Chip {
    for (&CHIPS) |*c| {
        if (std.ascii.eqlIgnoreCase(c.name, name)) return c;
    }
    return null;
}

/// What a chipset number Galaxy does not drive is, for the log (the other
/// families nouveau's table has, by their range).
pub fn familyName(chipset: u32) []const u8 {
    return switch (chipset & 0x1f0) {
        0x160 => "Turing",
        0x170 => "Ampere",
        0x190 => "Ada",
        0x180 => "Hopper",
        0x1a0 => "Blackwell (GB10x)",
        0x1b0 => "Blackwell (GB20x)",
        0x140 => "Volta",
        0x120, 0x130 => "Maxwell or Pascal",
        else => "unknown",
    };
}

/// The doorbell's work-submit token for channel `chid` on `runlist`.
pub fn token(c: *const Chip, runlist: u32, chid: u32) u32 {
    return (if (c.token_bit30) @as(u32, 1) << 30 else 0) | (runlist << 16) | chid;
}

/// The SMs the design has.
pub fn sms(c: *const Chip) u32 {
    return c.gpcs * c.tpcs_per_gpc * c.sms_per_tpc;
}

const testing = std.testing;

test "chips: PMC_BOOT_0 names the RTX 2080 Ti's TU102 and the Legion's GB206" {
    const tu = of(0x1620_00a1) orelse return error.NoChip;
    try testing.expectEqualStrings("TU102", tu.name);
    try testing.expectEqual(Family.turing, tu.family);
    try testing.expectEqual(Boot.sec2, tu.boot);
    try testing.expectEqual(Mmu.v2, tu.mmu);
    try testing.expectEqual(Sm.sm_75, tu.sm);
    try testing.expectEqual(@as(u32, 0xc5c0), tu.classes.compute);
    try testing.expectEqual(@as(u32, 0xc46f), tu.classes.channel);
    try testing.expectEqual(@as(u32, 0xc597), tu.classes.threed);
    try testing.expectEqual(@as(u32, 0x088000), tu.cfg_mirror);
    try testing.expectEqualStrings(".fwsignature_tu10x", tu.sig_section);
    try testing.expect(!tu.proven);
    try testing.expectEqual(@as(u32, 72), sms(tu));
    const gb = of(0x1b60_00a1) orelse return error.NoChip;
    try testing.expectEqualStrings("GB206", gb.name);
    try testing.expectEqual(Boot.fsp, gb.boot);
    try testing.expectEqual(Mmu.v3, gb.mmu);
    try testing.expectEqual(@as(u32, 0xcec0), gb.classes.compute);
    try testing.expect(gb.proven);
    try testing.expect(TU102 == tu and GB206 == gb);
}

test "chips: chips Galaxy does not drive are named by family, not taken" {
    try testing.expect(of(0x1720_00a1) == null); // GA102
    try testing.expectEqualStrings("Ampere", familyName(0x172));
    try testing.expectEqualStrings("Ada", familyName(0x192));
    try testing.expectEqualStrings("Turing", familyName(0x168));
    try testing.expect(byName("tu102") == TU102);
    try testing.expect(byName("GB206") == GB206);
    try testing.expect(byName("rtx") == null);
}

test "chips: the doorbell's token (Turing: runlist and channel; GB20x: bit 30 too)" {
    try testing.expectEqual(@as(u32, 0x0003_0002), token(TU102, 3, 2));
    try testing.expectEqual(@as(u32, 0x4003_0002), token(GB206, 3, 2));
    try testing.expectEqual(@as(u32, 0x75), Sm.sm_75.sass());
    try testing.expectEqual(@as(u32, 0xa4), Sm.sm_120.sass());
}
