//! @zpm/amdgpu dispatch — what a compute dispatch on a gfx8 GPU needs to
//! know about a kernel: the register counts, the user and system SGPRs the
//! hardware fills before the first instruction, the workitem-id VGPRs, LDS
//! and scratch, as the 64-byte AMDHSA kernel descriptor holds them and as
//! the COMPUTE_* registers a PM4 SET_SH_REG writes take them.
//!
//! The descriptor layout and the RSRC1/RSRC2 fields are LLVM's AMDGPUUsage
//! "Kernel Descriptor" (GFX6-GFX9) and AMD's GCN3 ISA guide; the register
//! addresses are Mesa's sid.h (read as documentation). The PM4 packets
//! themselves are Galaxy's (its driver writes SET_SH_REG and DISPATCH_DIRECT
//! from these values).
//!
//! Allocation-free: plain values.

const std = @import("std");

/// The user SGPRs a kernel can ask for, in the order the hardware loads
/// them (s0 upwards), with their sizes in dwords.
pub const UserSgpr = enum(u3) {
    private_segment_buffer, // 4: the scratch V#
    dispatch_ptr, // 2: the AQL dispatch packet
    queue_ptr, // 2
    kernarg_segment_ptr, // 2: the kernel arguments
    dispatch_id, // 2
    flat_scratch_init, // 2
    private_segment_size, // 1

    pub fn dwords(u: UserSgpr) u8 {
        return switch (u) {
            .private_segment_buffer => 4,
            .private_segment_size => 1,
            else => 2,
        };
    }
};

/// The kernel's register and segment needs, the inputs to the descriptor.
pub const Config = struct {
    /// Bitset of UserSgpr.
    user_sgprs: u8 = 0,
    /// System SGPRs after the user SGPRs: workgroup id x, y, z, workgroup
    /// info, private segment wave offset.
    workgroup_id: [3]bool = .{ true, false, false },
    workgroup_info: bool = false,
    private_segment_wave_offset: bool = false,
    /// Workitem ids delivered in v0, v1, v2: 0 = x, 1 = x and y, 2 = x, y, z.
    workitem_id: u2 = 0,
    /// VGPRs and SGPRs the code names (highest + 1).
    next_free_vgpr: u16 = 1,
    next_free_sgpr: u16 = 0,
    /// VCC and FLAT_SCRATCH are allocated at the top of the SGPRs (gfx8).
    reserve_vcc: bool = true,
    reserve_flat_scratch: bool = false,
    group_segment_bytes: u32 = 0,
    private_segment_bytes: u32 = 0,
    kernarg_bytes: u32 = 0,
    /// MODE at launch: round to nearest even; f32 denormals flushed, f16/f64
    /// kept (LLVM's default); IEEE mode and DX10 clamp on.
    float_round_mode_32: u2 = 0,
    float_round_mode_16_64: u2 = 0,
    float_denorm_mode_32: u2 = 0,
    float_denorm_mode_16_64: u2 = 3,
    dx10_clamp: bool = true,
    ieee_mode: bool = true,
    priority: u2 = 0,

    pub fn has(c: *const Config, u: UserSgpr) bool {
        return c.user_sgprs >> @intFromEnum(u) & 1 != 0;
    }

    pub fn userSgprCount(c: *const Config) u8 {
        var n: u8 = 0;
        for (std.enums.values(UserSgpr)) |u| {
            if (c.has(u)) n += u.dwords();
        }
        return n;
    }

    /// The first SGPR of a user SGPR the kernel asked for.
    pub fn userSgpr(c: *const Config, which: UserSgpr) ?u8 {
        if (!c.has(which)) return null;
        var n: u8 = 0;
        for (std.enums.values(UserSgpr)) |u| {
            if (u == which) return n;
            if (c.has(u)) n += u.dwords();
        }
        unreachable;
    }

    pub fn systemSgprCount(c: *const Config) u8 {
        var n: u8 = 0;
        for (c.workgroup_id) |e| n += @intFromBool(e);
        return n + @intFromBool(c.workgroup_info) + @intFromBool(c.private_segment_wave_offset);
    }

    /// The SGPR holding workgroup id x/y/z (axis 0..2), if enabled.
    pub fn workgroupIdSgpr(c: *const Config, axis: u2) ?u8 {
        if (!c.workgroup_id[axis]) return null;
        var n = c.userSgprCount();
        for (0..axis) |i| n += @intFromBool(c.workgroup_id[i]);
        return n;
    }

    /// SGPRs the wave is allocated, as RSRC1 counts them: the code's, at
    /// least the ones the hardware writes, plus VCC and FLAT_SCRATCH
    /// (LLVM's getNumExtraSGPRs for gfx8: 2 for VCC, 6 with FLAT_SCRATCH).
    pub fn sgprs(c: *const Config) u16 {
        const named = @max(c.next_free_sgpr, @as(u16, c.userSgprCount()) + c.systemSgprCount());
        var extra: u16 = 0;
        if (c.reserve_vcc) extra = 2;
        if (c.reserve_flat_scratch) extra = 6;
        return named + extra;
    }

    pub fn vgprs(c: *const Config) u16 {
        return @max(c.next_free_vgpr, @as(u16, c.workitem_id) + 1);
    }

    pub fn rsrc1(c: *const Config) u32 {
        const vgpr_blocks = (alignUp(@max(c.vgprs(), 1), 4) / 4) - 1;
        const sgpr_blocks = (alignUp(@max(c.sgprs(), 1), 8) / 8) - 1;
        return @as(u32, vgpr_blocks) |
            @as(u32, sgpr_blocks) << 6 |
            @as(u32, c.priority) << 10 |
            @as(u32, c.float_round_mode_32) << 12 |
            @as(u32, c.float_round_mode_16_64) << 14 |
            @as(u32, c.float_denorm_mode_32) << 16 |
            @as(u32, c.float_denorm_mode_16_64) << 18 |
            @as(u32, @intFromBool(c.dx10_clamp)) << 21 |
            @as(u32, @intFromBool(c.ieee_mode)) << 23;
    }

    /// RSRC2 as the descriptor holds it (LDS_SIZE 0: the dispatch fills it
    /// in, see rsrc2Dispatch).
    pub fn rsrc2(c: *const Config) u32 {
        return @as(u32, @intFromBool(c.private_segment_wave_offset)) |
            @as(u32, c.userSgprCount()) << 1 |
            @as(u32, @intFromBool(c.workgroup_id[0])) << 7 |
            @as(u32, @intFromBool(c.workgroup_id[1])) << 8 |
            @as(u32, @intFromBool(c.workgroup_id[2])) << 9 |
            @as(u32, @intFromBool(c.workgroup_info)) << 10 |
            @as(u32, c.workitem_id) << 11;
    }

    /// RSRC2 for COMPUTE_PGM_RSRC2 at dispatch: LDS_SIZE (bits 23:15) in
    /// 512-byte granules (gfx7 and later).
    pub fn rsrc2Dispatch(c: *const Config, dynamic_lds_bytes: u32) u32 {
        const lds = c.group_segment_bytes + dynamic_lds_bytes;
        const blocks = (lds + 511) / 512;
        return c.rsrc2() | (blocks & 0x1ff) << 15;
    }

    pub fn kernelCodeProperties(c: *const Config) u16 {
        return c.user_sgprs;
    }
};

fn alignUp(x: u16, a: u16) u16 {
    return (x + a - 1) / a * a;
}

/// The 64-byte AMDHSA kernel descriptor (code object v3 and later).
pub const Descriptor = struct {
    group_segment_fixed_size: u32 = 0,
    private_segment_fixed_size: u32 = 0,
    kernarg_size: u32 = 0,
    /// From the descriptor to the code (256-byte aligned).
    kernel_code_entry_byte_offset: i64 = 0,
    compute_pgm_rsrc3: u32 = 0,
    compute_pgm_rsrc1: u32 = 0,
    compute_pgm_rsrc2: u32 = 0,
    kernel_code_properties: u16 = 0,

    pub fn from(c: *const Config, entry_offset: i64) Descriptor {
        return .{
            .group_segment_fixed_size = c.group_segment_bytes,
            .private_segment_fixed_size = c.private_segment_bytes,
            .kernarg_size = c.kernarg_bytes,
            .kernel_code_entry_byte_offset = entry_offset,
            .compute_pgm_rsrc1 = c.rsrc1(),
            .compute_pgm_rsrc2 = c.rsrc2(),
            .kernel_code_properties = c.kernelCodeProperties(),
        };
    }

    pub fn bytes(d: *const Descriptor) [64]u8 {
        var b = [_]u8{0} ** 64;
        std.mem.writeInt(u32, b[0..4], d.group_segment_fixed_size, .little);
        std.mem.writeInt(u32, b[4..8], d.private_segment_fixed_size, .little);
        std.mem.writeInt(u32, b[8..12], d.kernarg_size, .little);
        std.mem.writeInt(i64, b[16..24], d.kernel_code_entry_byte_offset, .little);
        std.mem.writeInt(u32, b[44..48], d.compute_pgm_rsrc3, .little);
        std.mem.writeInt(u32, b[48..52], d.compute_pgm_rsrc1, .little);
        std.mem.writeInt(u32, b[52..56], d.compute_pgm_rsrc2, .little);
        std.mem.writeInt(u16, b[56..58], d.kernel_code_properties, .little);
        return b;
    }

    pub fn parse(b: *const [64]u8) Descriptor {
        return .{
            .group_segment_fixed_size = std.mem.readInt(u32, b[0..4], .little),
            .private_segment_fixed_size = std.mem.readInt(u32, b[4..8], .little),
            .kernarg_size = std.mem.readInt(u32, b[8..12], .little),
            .kernel_code_entry_byte_offset = std.mem.readInt(i64, b[16..24], .little),
            .compute_pgm_rsrc3 = std.mem.readInt(u32, b[44..48], .little),
            .compute_pgm_rsrc1 = std.mem.readInt(u32, b[48..52], .little),
            .compute_pgm_rsrc2 = std.mem.readInt(u32, b[52..56], .little),
            .kernel_code_properties = std.mem.readInt(u16, b[56..58], .little),
        };
    }
};

// ── The COMPUTE_* registers (Mesa's sid.h byte addresses) ───────────────────

pub const COMPUTE_DISPATCH_INITIATOR: u32 = 0xB800;
pub const COMPUTE_DIM_X: u32 = 0xB804;
pub const COMPUTE_START_X: u32 = 0xB810;
pub const COMPUTE_NUM_THREAD_X: u32 = 0xB81C;
pub const COMPUTE_NUM_THREAD_Y: u32 = 0xB820;
pub const COMPUTE_NUM_THREAD_Z: u32 = 0xB824;
pub const COMPUTE_PGM_LO: u32 = 0xB830;
pub const COMPUTE_PGM_HI: u32 = 0xB834;
pub const COMPUTE_PGM_RSRC1: u32 = 0xB848;
pub const COMPUTE_PGM_RSRC2: u32 = 0xB84C;
pub const COMPUTE_RESOURCE_LIMITS: u32 = 0xB854;
pub const COMPUTE_TMPRING_SIZE: u32 = 0xB860;
pub const COMPUTE_USER_DATA_0: u32 = 0xB900;
/// SET_SH_REG takes registers as dword offsets from here.
pub const SH_REG_BASE: u32 = 0xB000;

/// DISPATCH_INITIATOR: COMPUTE_SHADER_EN | FORCE_START_AT_000 | ORDER_MODE
/// (what Mesa's radeonsi sets on gfx7 and gfx8).
pub const DISPATCH_INITIATOR: u32 = 1 << 0 | 1 << 2 | 1 << 6;

pub fn shRegOffset(addr: u32) u32 {
    return (addr - SH_REG_BASE) / 4;
}

pub const Reg = struct { addr: u32, value: u32 };

/// The register writes of one dispatch, in address order within groups (one
/// SET_SH_REG per run of consecutive registers).
pub const ShRegs = struct {
    regs: [32]Reg = undefined,
    n: usize = 0,

    fn put(s: *ShRegs, addr: u32, value: u32) void {
        s.regs[s.n] = .{ .addr = addr, .value = value };
        s.n += 1;
    }

    pub fn slice(s: *const ShRegs) []const Reg {
        return s.regs[0..s.n];
    }
};

pub const Error = error{ Misaligned, TooManyUserSgprs, BadWorkgroup };

/// What a dispatch of the kernel at `code_va` writes. `user_data` are the
/// user SGPR values in the order Config lays them out (kernarg pointer
/// etc.); `scratch_waves` the waves given scratch (0 without).
pub fn shRegs(c: *const Config, code_va: u64, workgroup: [3]u16, user_data: []const u32, dynamic_lds_bytes: u32, scratch_waves: u32) Error!ShRegs {
    if (code_va & 0xff != 0) return error.Misaligned;
    if (user_data.len != c.userSgprCount() or user_data.len > 16) return error.TooManyUserSgprs;
    for (workgroup) |w| {
        if (w == 0) return error.BadWorkgroup;
    }
    if (@as(u32, workgroup[0]) * workgroup[1] * workgroup[2] > 1024) return error.BadWorkgroup;
    var s = ShRegs{};
    s.put(COMPUTE_START_X, 0);
    s.put(COMPUTE_START_X + 4, 0);
    s.put(COMPUTE_START_X + 8, 0);
    s.put(COMPUTE_NUM_THREAD_X, workgroup[0]);
    s.put(COMPUTE_NUM_THREAD_Y, workgroup[1]);
    s.put(COMPUTE_NUM_THREAD_Z, workgroup[2]);
    s.put(COMPUTE_PGM_LO, @truncate(code_va >> 8));
    s.put(COMPUTE_PGM_HI, @truncate(code_va >> 40 & 0xff));
    s.put(COMPUTE_PGM_RSRC1, c.rsrc1());
    s.put(COMPUTE_PGM_RSRC2, c.rsrc2Dispatch(dynamic_lds_bytes));
    s.put(COMPUTE_RESOURCE_LIMITS, 0);
    // WAVES (11:0) and WAVESIZE (24:12, in 256-dword units per wave).
    const per_wave = (c.private_segment_bytes * 64 + 1023) / 1024;
    s.put(COMPUTE_TMPRING_SIZE, if (c.private_segment_bytes == 0) 0 else (scratch_waves & 0xfff) | (per_wave & 0x1fff) << 12);
    for (user_data, 0..) |x, i| s.put(COMPUTE_USER_DATA_0 + 4 * @as(u32, @intCast(i)), x);
    return s;
}

// ── Buffer resources (V#) ───────────────────────────────────────────────────

/// A gfx8 buffer resource: base (48 bits), stride (14), num_records, and
/// the dst_sel/format word (a raw 32-bit buffer by default).
pub const BufferResource = struct {
    base: u64,
    stride: u16 = 0,
    num_records: u32,
    /// DST_SEL_XYZW = XYZW, NUM_FORMAT = FLOAT, DATA_FORMAT = 32.
    word3: u32 = 4 | 5 << 3 | 6 << 6 | 7 << 9 | 7 << 12 | 4 << 15,

    pub fn words(r: BufferResource) [4]u32 {
        return .{
            @truncate(r.base),
            @as(u32, @truncate(r.base >> 32 & 0xffff)) | @as(u32, r.stride & 0x3fff) << 16,
            r.num_records,
            r.word3,
        };
    }

    pub fn fromWords(w: [4]u32) BufferResource {
        return .{
            .base = @as(u64, w[0]) | @as(u64, w[1] & 0xffff) << 32,
            .stride = @intCast(w[1] >> 16 & 0x3fff),
            .num_records = w[2],
            .word3 = w[3],
        };
    }
};

test "the descriptor: LLVM's layout and RSRC fields for a kernarg kernel" {
    var c = Config{ .user_sgprs = 1 << @intFromEnum(UserSgpr.kernarg_segment_ptr), .next_free_vgpr = 9, .next_free_sgpr = 11, .group_segment_bytes = 2048, .kernarg_bytes = 28, .workitem_id = 1 };
    c.workgroup_id = .{ true, true, false };
    try std.testing.expectEqual(@as(u8, 0), c.userSgpr(.kernarg_segment_ptr).?);
    try std.testing.expectEqual(@as(u8, 2), c.workgroupIdSgpr(0).?);
    try std.testing.expectEqual(@as(u8, 3), c.workgroupIdSgpr(1).?);
    // 11 SGPRs + VCC = 13 -> 2 granules of 8 -> 1; 9 VGPRs -> 3 granules of 4 -> 2
    try std.testing.expectEqual(@as(u32, 2 | 1 << 6 | 3 << 18 | 1 << 21 | 1 << 23), c.rsrc1());
    try std.testing.expectEqual(@as(u32, 2 << 1 | 1 << 7 | 1 << 8 | 1 << 11), c.rsrc2());
    try std.testing.expectEqual(c.rsrc2() | 4 << 15, c.rsrc2Dispatch(0));
    const d = Descriptor.from(&c, -0x100);
    const b = d.bytes();
    const back = Descriptor.parse(&b);
    try std.testing.expectEqual(d, back);
    try std.testing.expectEqual(@as(u8, 8), b[56]);
    const regs = try shRegs(&c, 0x1_2345_6700, .{ 16, 16, 1 }, &.{ 0x1000, 0x1 }, 0, 0);
    var saw_lo = false;
    for (regs.slice()) |r| {
        if (r.addr == COMPUTE_PGM_LO) {
            try std.testing.expectEqual(@as(u32, 0x01234567), r.value);
            saw_lo = true;
        }
        if (r.addr == COMPUTE_USER_DATA_0 + 4) try std.testing.expectEqual(@as(u32, 1), r.value);
    }
    try std.testing.expect(saw_lo);
    try std.testing.expectEqual(@as(u32, 0x20C), shRegOffset(COMPUTE_PGM_LO));
}

test "a buffer resource packs base, stride and records" {
    const r = BufferResource{ .base = 0x1234_5678_9abc, .stride = 16, .num_records = 100 };
    const w = r.words();
    try std.testing.expectEqual(@as(u32, 0x5678_9abc), w[0]);
    try std.testing.expectEqual(@as(u32, 0x1234 | 16 << 16), w[1]);
    try std.testing.expectEqual(r, BufferResource.fromWords(w));
}
