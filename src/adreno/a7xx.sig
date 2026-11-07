//! @zpm/adreno a7xx — command streams that run compute kernels on an A7xx
//! (the Adreno X1-45 of the Surface Laptop 13: a7xx gen 2, the a740
//! register set).
//!
//! Register offsets, packet layouts and the per-GPU "magic" register values
//! were written down from Mesa's register database
//! (src/freedreno/registers/adreno/a6xx.xml, adreno_pm4.xml), its device
//! table (src/freedreno/common/freedreno_devices.py, the X1-45 entry) and
//! the minimal compute recipe of its computerator tool
//! (src/freedreno/computerator/a6xx.cc), all used as documentation only.
//!
//! A stream is built into caller memory (dwords) and is meant to be run as
//! an indirect buffer from the kernel's ring: Galaxy's driver adds the
//! fence and the cache clean after it.

const std = @import("std");
const ir3 = @import("ir3.sig");
const ir3_asm = @import("ir3_asm.sig");

pub const Error = error{ StreamFull, BadKernel };

// ── Packets ─────────────────────────────────────────────────────────────────

fn parity(v: u32) u32 {
    const x = v ^ (v >> 4) ^ (v >> 8) ^ (v >> 12) ^ (v >> 16) ^ (v >> 20) ^ (v >> 24) ^ (v >> 28);
    return (@as(u32, 0x9669) >> @intCast(x & 0xf)) & 1;
}

/// Type-4 packet header: `cnt` consecutive registers from `reg`.
pub fn pkt4(reg: u32, cnt: u32) u32 {
    return (4 << 28) | cnt | (parity(cnt) << 7) | ((reg & 0x3ffff) << 8) | (parity(reg) << 27);
}

/// Type-7 packet header: opcode `op` with `cnt` payload dwords.
pub fn pkt7(op: u32, cnt: u32) u32 {
    return (7 << 28) | cnt | (parity(cnt) << 15) | ((op & 0x7f) << 16) | (parity(op) << 23);
}

// ── PM4 opcodes (adreno_pm4.xml) ────────────────────────────────────────────

pub const CP_NOP = 0x10;
pub const CP_WAIT_MEM_WRITES = 0x12;
pub const CP_WAIT_FOR_ME = 0x13;
pub const CP_WAIT_TIMESTAMP = 0x14;
pub const CP_THREAD_CONTROL = 0x17;
pub const CP_WAIT_FOR_IDLE = 0x26;
pub const CP_EXEC_CS = 0x33;
pub const CP_LOAD_STATE6_FRAG = 0x34;
pub const CP_WAIT_REG_MEM = 0x3c;
pub const CP_MEM_WRITE = 0x3d;
pub const CP_REG_TO_MEM = 0x3e;
pub const CP_INDIRECT_BUFFER = 0x3f;
pub const CP_EVENT_WRITE7 = 0x46;
pub const CP_SET_MARKER = 0x65;
pub const CP_MEM_TO_MEM = 0x73;

// Events (vgt_event_type, A7XX).
pub const RB_DONE_TS = 0x16;
pub const CACHE_CLEAN = 0x31;
pub const CACHE_FLUSH7 = 0x32;
pub const CACHE_INVALIDATE7 = 0x33;

pub const RM6_COMPUTE = 8;

// CP_LOAD_STATE6
pub const ST6_SHADER = 0;
pub const ST6_CONSTANTS = 1;
pub const ST6_UBO = 2;
pub const ST6_UAV = 3;
pub const SS6_DIRECT = 0;
pub const SS6_INDIRECT = 2;
pub const SB6_CS_SHADER = 0xd;

// ── Registers (a6xx.xml, A7XX variants; dword offsets) ─────────────────────

pub const CP_ALWAYS_ON_COUNTER = 0x0980;
pub const UCHE_CACHE_WAYS = 0x0e17;
pub const SP_CS_CNTL_0 = 0xa9b0;
pub const SP_CS_CNTL_1 = 0xa9b1;
pub const SP_CS_BASE = 0xa9b4;
pub const SP_CS_CONFIG = 0xa9bb;
pub const SP_CS_INSTR_SIZE = 0xa9bc;
pub const SP_CS_WIE_CNTL_0 = 0xa9c2;
pub const SP_CS_WIE_CNTL_1 = 0xa9c3;
pub const SP_PS_WAVE_CNTL = 0xa9c6;
pub const SP_REG_PROG_ID_0 = 0xa9c8;
pub const SP_CS_CONST_CONFIG = 0xa9cd;
pub const SP_CS_NDRANGE_0 = 0xa9d4;
pub const SP_CS_WGE_CNTL = 0xa9db;
pub const SP_CS_KERNEL_GROUP_X = 0xa9dc;
pub const SP_CS_NDRANGE_7 = 0xa9df;
pub const SP_MODE_CNTL = 0xab00;
pub const SP_UPDATE_CNTL = 0xab1f;
pub const SP_NC_MODE_CNTL_2 = 0xae04;
pub const SP_PERFCTR_SHADER_MASK = 0xae0f;

/// The X1-45's per-GPU register values (Mesa's raw_magic_regs for
/// "Adreno X1-45", the same the vendor driver writes).
pub const x1_45_magic = [_][2]u32{
    .{ UCHE_CACHE_WAYS, 0x00000000 },
    .{ 0xb600, 0x11100000 }, // TPL1_DBG_ECO_CNTL
    .{ 0xb602, 0x00040724 }, // TPL1_DBG_ECO_CNTL1
    .{ 0xae03, 0x10001400 }, // SP_CHICKEN_BITS
    .{ 0xae08, 0x00400400 }, // SP_CHICKEN_BITS_1
    .{ 0xae09, 0x00430800 }, // SP_CHICKEN_BITS_2
    .{ 0xae0a, 0x00000000 }, // SP_CHICKEN_BITS_3
    .{ 0x0e10, 0x00000000 }, // UCHE_UNKNOWN_0E10
    .{ 0x0e11, 0x00000000 }, // UCHE_UNKNOWN_0E11
    .{ 0xae6c, 0x00000000 }, // SP_HLSQ_DBG_ECO_CNTL
    .{ 0xae00, 0x10000000 }, // SP_DBG_ECO_CNTL
    .{ 0x9804, 0x00001f1f }, // PC_MODE_CNTL
    .{ 0x9e00, 0x00100000 }, // PC_DBG_ECO_CNTL
    .{ 0x9e24, 0x01585600 }, // PC_UNKNOWN_9E24
    .{ 0xa600, 0x00008000 }, // VFD_DBG_ECO_CNTL
    .{ 0xae06, 0x00000000 }, // SP_ISDB_CNTL
    .{ 0xae6a, 0x00000000 }, // SP_UNKNOWN_AE6A
    .{ 0xae6b, 0x00000080 }, // SP_HLSQ_TIMEOUT_THRESHOLD_DP
    .{ 0xae73, 0x00000000 }, // SP_HLSQ_DBG_ECO_CNTL_1
    .{ 0xab02, 0x00000000 }, // SP_HLSQ_MODE_CNTL
    .{ 0xab01, 0x00000000 }, // SP_UNKNOWN_AB01
    .{ 0xab22, 0x00000000 }, // SP_UNKNOWN_AB22
    .{ 0xb310, 0x00000000 }, // SP_UNKNOWN_B310
    .{ 0x0ce2, 0x00000000 }, // SP_UNKNOWN_0CE2
    .{ 0x0ce3, 0x00000000 },
    .{ 0x0ce4, 0x00000000 }, // SP_UNKNOWN_0CE4
    .{ 0x0ce5, 0x00000000 },
    .{ 0x0ce6, 0x00000000 }, // SP_UNKNOWN_0CE6
    .{ 0x0ce7, 0x00000000 },
    .{ 0x80a7, 0x00000000 }, // GRAS_ROTATION_CNTL
    .{ 0x8600, 0x00004800 }, // GRAS_DBG_ECO_CNTL
    .{ 0x8e01, 0x00000000 }, // RB_RBP_CNTL
    .{ 0x8e79, 0x00000000 }, // RB_UNKNOWN_8E79
    .{ 0x8899, 0x00000000 }, // RB_LRZ_CNTL2
    .{ 0x8e06, 0x02080000 }, // RB_CCU_DBG_ECO_CNTL
    .{ 0x9600, 0x02000000 }, // VPC_DBG_ECO_CNTL
    .{ 0x0e12, 0x00000000 }, // UCHE_UNKNOWN_0E12
    .{ 0x8e04, 0x00000001 }, // RB_DBG_ECO_CNTL
};

// ── The stream ──────────────────────────────────────────────────────────────

pub const Stream = struct {
    buf: []u32,
    len: usize = 0,
    full: bool = false,

    pub fn emit(s: *Stream, v: u32) void {
        if (s.len >= s.buf.len) {
            s.full = true;
            return;
        }
        s.buf[s.len] = v;
        s.len += 1;
    }

    pub fn emit64(s: *Stream, v: u64) void {
        s.emit(@truncate(v));
        s.emit(@truncate(v >> 32));
    }

    pub fn reg(s: *Stream, r: u32, v: u32) void {
        s.emit(pkt4(r, 1));
        s.emit(v);
    }

    pub fn reg64(s: *Stream, r: u32, v: u64) void {
        s.emit(pkt4(r, 2));
        s.emit64(v);
    }

    pub fn regs(s: *Stream, r: u32, vals: []const u32) void {
        s.emit(pkt4(r, @intCast(vals.len)));
        for (vals) |v| s.emit(v);
    }

    pub fn pkt(s: *Stream, op: u32, payload: []const u32) void {
        s.emit(pkt7(op, @intCast(payload.len)));
        for (payload) |v| s.emit(v);
    }

    pub fn words(s: *const Stream) []const u32 {
        return s.buf[0..s.len];
    }

    pub fn check(s: *const Stream) Error!void {
        if (s.full) return error.StreamFull;
    }

    /// Run on the BR pipe only (the compute pipe of the a7xx's two), with
    /// concurrent binning off.
    pub fn threadBr(s: *Stream) void {
        s.pkt(CP_THREAD_CONTROL, &.{1 | (1 << 27)});
    }

    pub fn waitForIdle(s: *Stream) void {
        s.pkt(CP_WAIT_FOR_IDLE, &.{});
    }

    pub fn event(s: *Stream, ev: u32) void {
        s.pkt(CP_EVENT_WRITE7, &.{ev});
    }

    /// UCHE invalidate: the GPU reads what the CPU wrote since.
    pub fn invalidateCaches(s: *Stream) void {
        s.event(CACHE_INVALIDATE7);
    }

    /// UCHE clean: what the GPU wrote reaches memory.
    pub fn cleanCaches(s: *Stream) void {
        s.event(CACHE_CLEAN);
    }

    /// The GPU's always-on counter (19.2 MHz) into memory, once everything
    /// before it is done (a timestamp for measuring).
    pub fn timestamp(s: *Stream, va: u64) void {
        s.waitForIdle();
        s.pkt(CP_REG_TO_MEM, &.{ CP_ALWAYS_ON_COUNTER | (2 << 18) | (1 << 30), @truncate(va), @truncate(va >> 32) });
    }

    /// Write `value` to `va` from the CP (a marker: how far a stream got).
    pub fn memWrite(s: *Stream, va: u64, value: u32) void {
        s.pkt(CP_MEM_WRITE, &.{ @truncate(va), @truncate(va >> 32), value });
    }

    /// The per-GPU state compute needs, once per stream.
    pub fn computeSetup(s: *Stream) void {
        s.threadBr();
        s.reg(SP_PERFCTR_SHADER_MASK, 1 << 5);
        s.reg(SP_NC_MODE_CNTL_2, 0);
        for (x1_45_magic) |m| s.reg(m[0], m[1]);
        // const demotion on, isam mode GL
        s.reg(SP_MODE_CNTL, 1 | (2 << 1));
        s.invalidateCaches();
    }

    /// Program a kernel whose code is at GPU address `code_va`.
    pub fn program(s: *Stream, k: *const ir3_asm.Kernel, code_va: u64) Error!void {
        if (code_va & 127 != 0 or k.instrlen == 0) return error.BadKernel;
        const thread128: u32 = @intFromBool(k.threadsize == 128);
        // throw away state loads still queued for any stage
        s.reg(SP_UPDATE_CNTL, 0x3f | (1 << 7));
        const constlen = std.mem.alignForward(u32, @max(k.constlen, 4), 4);
        s.reg(SP_CS_CONST_CONFIG, (constlen >> 2) | (1 << 8));
        s.reg(SP_CS_CONFIG, 1 << 8);
        s.reg(SP_CS_INSTR_SIZE, k.instrlen);
        const branchstack: u32 = std.mem.alignForward(u32, @min(k.branchstack, 64), 2);
        s.reg(SP_CS_CNTL_0, (@as(u32, @max(k.half_regs, 1)) << 1) | (@as(u32, @max(k.full_regs, 1)) << 7) | (branchstack << 13) | (thread128 << 20) | (1 << 31));
        s.reg(SP_PS_WAVE_CNTL, 0);
        s.regs(SP_REG_PROG_ID_0, &.{ 0xfcfcfcfc, 0xfcfcfcfc, 0xfcfcfcfc, 0x0000fc00 });
        const shared: u32 = if (k.shared_bytes == 0) 1 else @max((k.shared_bytes - 1) / 1024, 1);
        const ram_mode: u32 = if (constlen > 256) 3 else if (constlen > 192) 2 else if (constlen > 128) 1 else 0;
        s.reg(SP_CS_CNTL_1, @min(shared, 31) | (ram_mode << 5));
        const ly = k.local_size[1];
        const tile_h: u32 = if (ly % 8 == 0) 3 else if (ly % 4 == 0) 5 else if (ly % 2 == 0) 9 else 17;
        s.reg(SP_CS_WGE_CNTL, ir3_asm.INVALID_REG | (thread128 << 9) | (1 << 11) | (4 << 20) | (tile_h << 26));
        s.reg(SP_CS_WIE_CNTL_0, @as(u32, k.wgid_reg) | (@as(u32, ir3_asm.INVALID_REG) << 8) | (@as(u32, ir3_asm.INVALID_REG) << 16) | (@as(u32, k.localid_reg) << 24));
        s.reg(SP_CS_WIE_CNTL_1, ir3_asm.INVALID_REG | (thread128 << 8));
        s.reg64(SP_CS_BASE, code_va);
        // Preload the instructions (the cache holds 127 lines of 16).
        const preload: u32 = @min(k.instrlen, 127);
        s.pkt(CP_LOAD_STATE6_FRAG, &.{ (ST6_SHADER << 14) | (SS6_INDIRECT << 16) | (SB6_CS_SHADER << 18) | (preload << 22), @truncate(code_va), @truncate(code_va >> 32) });
    }

    /// Constants c[first_vec4..] from `dwords` (a multiple of 4 dwords).
    /// (Direct, in the stream: the Surface's X1-45 put constants the CP
    /// loaded from memory into c2.. at c0 instead, 11-06; gpu's
    /// adreno_device loads all of a dispatch's at once from c0.)
    pub fn constants(s: *Stream, first_vec4: u32, dwords: []const u32) void {
        const units: u32 = @intCast((dwords.len + 3) / 4);
        s.emit(pkt7(CP_LOAD_STATE6_FRAG, 3 + units * 4));
        s.emit(first_vec4 | (ST6_CONSTANTS << 14) | (SS6_DIRECT << 16) | (SB6_CS_SHADER << 18) | (units << 22));
        s.emit(0);
        s.emit(0);
        for (dwords) |v| s.emit(v);
        var pad = units * 4 - dwords.len;
        while (pad > 0) : (pad -= 1) s.emit(0);
    }

    /// Launch `groups` workgroups of the programmed kernel.
    pub fn dispatch(s: *Stream, k: *const ir3_asm.Kernel, groups: [3]u32) void {
        s.pkt(CP_SET_MARKER, &.{RM6_COMPUTE});
        const lx: u32 = k.local_size[0];
        const ly: u32 = k.local_size[1];
        const lz: u32 = k.local_size[2];
        var dim: u32 = 3;
        if (groups[2] == 1 and lz == 1) dim = 2;
        if (dim == 2 and groups[1] == 1 and ly == 1) dim = 1;
        const local = ((lx - 1) << 2) | ((ly - 1) << 12) | ((lz - 1) << 22);
        s.reg(SP_CS_NDRANGE_0, dim | local);
        s.reg(SP_CS_NDRANGE_7, local);
        s.regs(SP_CS_NDRANGE_0 + 1, &.{ lx * groups[0], 0, ly * groups[1], 0, lz * groups[2], 0 });
        s.regs(SP_CS_KERNEL_GROUP_X, &.{ 1, 1, 1 });
        s.pkt(CP_EXEC_CS, &.{ 0, groups[0], groups[1], groups[2] });
    }
};

// ── Tests ───────────────────────────────────────────────────────────────────

test "packet headers match Galaxy's driver and Mesa" {
    // galaxy_gpu.sig's CP_NOP with 2 dwords and a CP_SCRATCH write.
    try std.testing.expectEqual(@as(u32, 0x70100002), pkt7(CP_NOP, 2));
    try std.testing.expectEqual(@as(u32, 0x48088501), pkt4(0x885, 1));
    // CP_EXEC_CS, 4 dwords (freedreno's packet tables).
    try std.testing.expectEqual(@as(u32, 0x70b30004), pkt7(CP_EXEC_CS, 4));
}

test "a dispatch stream: program, constants, launch" {
    var buf: [512]u32 = undefined;
    var s = Stream{ .buf = &buf };
    const code = [_]u64{0} ** 16;
    const k = ir3_asm.Kernel{ .gen = ir3.A7XX, .code = &code, .count = 1, .instrlen = 1, .local_size = .{ 64, 1, 1 }, .localid_reg = 0, .wgid_reg = 192, .full_regs = 3, .constlen = 8 };
    s.computeSetup();
    try s.program(&k, 0x1_0000_1000);
    s.constants(0, &.{ 1, 2, 3, 4, 5 });
    s.dispatch(&k, .{ 10, 1, 1 });
    s.waitForIdle();
    try s.check();
    const w = s.words();
    // The last packet before the wait is CP_EXEC_CS with the groups.
    try std.testing.expectEqual(pkt7(CP_WAIT_FOR_IDLE, 0), w[w.len - 1]);
    try std.testing.expectEqual(pkt7(CP_EXEC_CS, 4), w[w.len - 6]);
    try std.testing.expectEqual(@as(u32, 10), w[w.len - 4]);
    // The constants: 5 dwords padded to 8, after a header of 3.
    var found = false;
    for (w, 0..) |v, i| {
        if (v == pkt7(CP_LOAD_STATE6_FRAG, 3 + 8) and i + 3 + 8 <= w.len) {
            found = true;
            try std.testing.expectEqual(@as(u32, (ST6_CONSTANTS << 14) | (SB6_CS_SHADER << 18) | (2 << 22)), w[i + 1]);
            try std.testing.expectEqual(@as(u32, 5), w[i + 4 + 4]);
            try std.testing.expectEqual(@as(u32, 0), w[i + 4 + 5]);
        }
    }
    try std.testing.expect(found);
}
