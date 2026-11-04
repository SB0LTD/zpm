//! @zpm/nvidia qmd — a compute launch's Queue Meta Data (QMD version 05_00,
//! BLACKWELL_COMPUTE_B, clcec0qmd.h) and the constant buffer 0 a CUDA-style
//! sm_120 kernel reads.
//!
//! A QMD is the 384-byte record the compute engine reads for one grid: where
//! the program is, the grid and block, the registers, shared and local
//! memory a thread gets, and the constant buffers. SEND_PCAS_A hands its
//! address to the engine (push.sig). These are Galaxy's encodings
//! (src/kernel/nv_chan.sig), which ran M4, M5 and `keep` on the Legion 5's
//! RTX 5070 Laptop GPU; the fields are tinygrad's Blackwell template (MIT,
//! ops_nv.py, read as documentation), plus the shared memory a kernel
//! declares, sized as tinygrad sizes it.
//!
//! `decode` reads one back, field by field: the emulated device
//! (device.sig) launches from it as the engine would, so a QMD that is
//! wrong in what it says fails on the CPU too.
//!
//! Allocation-free: the caller owns the words.

const std = @import("std");

pub const Error = error{
    /// A field that does not hold the value (a grid or block too big, more
    /// shared or local memory than a CTA or thread can have).
    OutOfRange,
    /// Constant buffer 0 has no room for the parameters.
    TooManyParams,
    /// Not a QMD this module reads: not version 05_00, not a grid of CTAs.
    BadQmd,
};

pub const QMD_WORDS = 0x60;
pub const QMD_BYTES = QMD_WORDS * 4;

/// The QMD's SASS_VERSION for sm_120: ((sm >> 4) & 0xf0) | (sm & 0xf) of
/// GSP-RM's SM version 0xa04 (tinygrad's rule, sassOf).
pub const SASS_SM120: u32 = 0xa4;

pub fn sassOf(sm_version: u32) u32 {
    return ((sm_version >> 4) & 0xf0) | (sm_version & 0xf);
}

/// The VA windows the SMs take as shared and local memory, where nothing
/// is mapped (tinygrad's, above what it maps). Generic addresses in them
/// reach a CTA's shared memory and a thread's local memory; CUDA kernels
/// read them from constant buffer 0 (words 188..191).
pub const SHARED_WINDOW: u64 = 0x7294_0000_0000;
pub const LOCAL_WINDOW: u64 = 0x7293_0000_0000;

/// A thread's local memory window is 16 MiB of addresses: the QMD's low
/// size counts from 0, its high size down from here.
pub const LOCAL_TOP: u32 = 0x100_0000;
/// The stack's top (constant buffer 0's 0x37c, CUDA's): the high part's
/// 0x240 bytes above it are CUDA's own (the ABI's), the stack grows down.
pub const STACK_TOP: u32 = 0xfffdc0;
pub const STACK_RESERVED: u32 = LOCAL_TOP - STACK_TOP;

/// Shared memory a CTA always has (sm_90 and later reserve its first 1 KiB:
/// a kernel's own shared variables start at 0x400).
pub const RESERVED_SHARED: u32 = 0x400;
/// The most shared memory a CTA can have on sm_120: 99 KiB of its own, plus
/// the reserved 1 KiB (the SM's largest split, 100 KiB).
pub const MAX_SHARED: u32 = 100 * 1024;
/// The SM's shared memory splits, in KiB (tinygrad's choice of 32, 64,
/// 100), as the SM config fields count them: KiB / 4 + 1.
const SM_SPLITS_KIB = [_]u32{ 32, 64, 100 };
pub const SM_CONFIG_MAX: u32 = 0x1a;

/// Constant buffer 0, 0x400 bytes (the QMD has its size in 16-byte units):
/// the driver's 224 words (0x380 bytes, what CUDA kernels read on
/// Blackwell), then the kernel's parameters.
pub const CBUF0_WORDS = 0x100;
pub const DRIVER_WORDS = 224;
pub const CBUF0_BYTES: u32 = CBUF0_WORDS * 4;
pub const PARAMS_OFFSET: u32 = DRIVER_WORDS * 4;
pub const MAX_PARAMS = (CBUF0_WORDS - DRIVER_WORDS) * 4;

/// Where constant buffer 0 has what a kernel reads (bytes).
pub const CB_DESCRIPTOR: u32 = 0x358; // a global memory descriptor (desc[UR4]): 0
pub const CB_BLOCK: u32 = 0x360; // %ntid.x, .y, .z
pub const CB_GRID: u32 = 0x370; // %nctaid.x, .y, .z
pub const CB_STACK_TOP: u32 = 0x37c;

/// The 8 constant buffers a QMD can name.
pub const CBUFS = 8;

// ── Bit fields (clcec0qmd.h's MW(hi:lo)) ────────────────────────────────────

/// The QMD's bits hi:lo set to `v` (its low hi - lo + 1 bits).
pub fn set(q: *[QMD_WORDS]u32, hi: u32, lo: u32, v: u64) void {
    var bit = lo;
    var x = v;
    while (bit <= hi) : (bit += 1) {
        const mask = @as(u32, 1) << @intCast(bit % 32);
        if (x & 1 != 0) q[bit / 32] |= mask else q[bit / 32] &= ~mask;
        x >>= 1;
    }
}

/// The QMD's bits hi:lo.
pub fn get(q: *const [QMD_WORDS]u32, hi: u32, lo: u32) u64 {
    var v: u64 = 0;
    var bit = hi + 1;
    while (bit > lo) {
        bit -= 1;
        v = v << 1 | ((q[bit / 32] >> @intCast(bit % 32)) & 1);
    }
    return v;
}

/// The fields this module writes and reads, as clcec0qmd.h names them.
pub const F = struct {
    pub const QMD_GROUP_ID = .{ 149, 144 };
    pub const QMD_TYPE = .{ 153, 151 };
    pub const RELEASE_ENABLE0 = .{ 288, 288 };
    pub const RELEASE_STRUCTURE_SIZE0 = .{ 290, 289 };
    pub const RELEASE_PAYLOAD64B0 = .{ 300, 300 };
    pub const SASS_VERSION = .{ 455, 448 };
    pub const API_VISIBLE_CALL_LIMIT = .{ 456, 456 };
    pub const SAMPLER_INDEX = .{ 457, 457 };
    pub const QMD_MINOR_VERSION = .{ 467, 464 };
    pub const QMD_MAJOR_VERSION = .{ 471, 468 };
    /// INVALIDATE_TEXTURE_HEADER, _SAMPLER, _DATA_CACHE and
    /// INVALIDATE_SHADER_DATA_CACHE.
    pub const INVALIDATES = .{ 475, 472 };
    pub const RELEASE_SEMAPHORE0_ADDR_LOWER = .{ 511, 480 };
    pub const RELEASE_SEMAPHORE0_ADDR_UPPER = .{ 536, 512 };
    pub const RELEASE_SEMAPHORE0_PAYLOAD_LOWER = .{ 575, 544 };
    pub const RELEASE_SEMAPHORE0_PAYLOAD_UPPER = .{ 607, 576 };
    pub const CWD_MEMBAR_TYPE = .{ 625, 624 };
    pub const PROGRAM_ADDRESS_LOWER_SHIFTED4 = .{ 1055, 1024 };
    pub const PROGRAM_ADDRESS_UPPER_SHIFTED4 = .{ 1076, 1056 };
    pub const PROGRAM_PREFETCH_SIZE = .{ 1085, 1077 };
    pub const CTA_THREAD_DIMENSION0 = .{ 1103, 1088 };
    pub const CTA_THREAD_DIMENSION1 = .{ 1119, 1104 };
    pub const CTA_THREAD_DIMENSION2 = .{ 1127, 1120 };
    pub const REGISTER_COUNT = .{ 1136, 1128 };
    pub const BARRIER_COUNT = .{ 1141, 1137 };
    pub const SHARED_MEMORY_SIZE_SHIFTED7 = .{ 1162, 1152 };
    pub const MIN_SM_CONFIG_SHARED_MEM_SIZE = .{ 1168, 1163 };
    pub const MAX_SM_CONFIG_SHARED_MEM_SIZE = .{ 1174, 1169 };
    pub const TARGET_SM_CONFIG_SHARED_MEM_SIZE = .{ 1180, 1175 };
    pub const SHADER_LOCAL_MEMORY_LOW_SIZE_SHIFTED4 = .{ 1199, 1184 };
    pub const SHADER_LOCAL_MEMORY_HIGH_SIZE_SHIFTED4 = .{ 1215, 1200 };
    pub const GRID_WIDTH = .{ 1279, 1248 };
    pub const GRID_HEIGHT = .{ 1295, 1280 };
    pub const GRID_DEPTH = .{ 1327, 1312 };
    pub const PROGRAM_PREFETCH_ADDR_LOWER_SHIFTED = .{ 1919, 1888 };
    pub const PROGRAM_PREFETCH_ADDR_UPPER_SHIFTED = .{ 1936, 1920 };

    /// Constant buffer i's address (bits 6 up), size (16-byte units),
    /// valid and invalidate bits.
    pub fn cbAddrLower(i: u32) [2]u32 {
        return .{ 1375 + i * 64, 1344 + i * 64 };
    }
    pub fn cbAddrUpper(i: u32) [2]u32 {
        return .{ 1394 + i * 64, 1376 + i * 64 };
    }
    pub fn cbSize(i: u32) [2]u32 {
        return .{ 1407 + i * 64, 1395 + i * 64 };
    }
    pub fn cbValid(i: u32) [2]u32 {
        return .{ 1856 + i * 4, 1856 + i * 4 };
    }
    pub fn cbInvalidate(i: u32) [2]u32 {
        return .{ 1859 + i * 4, 1859 + i * 4 };
    }
};

fn put(q: *[QMD_WORDS]u32, f: anytype, v: u64) void {
    set(q, f[0], f[1], v);
}

fn at(q: *const [QMD_WORDS]u32, f: anytype) u64 {
    return get(q, f[0], f[1]);
}

const QMD_TYPE_GRID_CTA = 2;
const CWD_MEMBAR_L1_SYSMEMBAR = 1;

// ── Building one ────────────────────────────────────────────────────────────

/// What a launch's QMD says.
pub const Shape = struct {
    prog_va: u64,
    /// The program's bytes (its prefetch size, in 256-byte units).
    prog_bytes: u64,
    cbuf_va: u64,
    registers: u32,
    grid: [3]u32 = .{ 1, 1, 1 },
    block: [3]u32 = .{ 1, 1, 1 },
    /// Local memory a thread has from the top of its window down (the
    /// QMD's high size: CUDA's stack, localSize's per_thread); 0: none.
    local_bytes: u32 = 0,
    /// The kernel's own shared memory, after the reserved 1 KiB.
    shared_bytes: u32 = 0,
    sass: u32 = SASS_SM120,
};

/// A CTA's shared memory as the QMD has it: the reserved 1 KiB and the
/// kernel's own, to 128 bytes (tinygrad's).
pub fn sharedTotal(kernel_bytes: u32) Error!u32 {
    if (kernel_bytes > MAX_SHARED - RESERVED_SHARED) return error.OutOfRange;
    return alignUp32(RESERVED_SHARED + kernel_bytes, 128);
}

/// The SM's split for `total` bytes a CTA: the smallest of 32, 64 and 100
/// KiB it fits, as KiB / 4 + 1 (tinygrad's).
pub fn smConfig(total: u32) Error!u32 {
    for (SM_SPLITS_KIB) |kib| {
        if (kib * 1024 >= total) return kib / 4 + 1;
    }
    return error.OutOfRange;
}

/// Shared memory bytes the SM config value `cfg` gives the SM.
pub fn smConfigBytes(cfg: u32) u32 {
    return (cfg -| 1) * 4096;
}

/// A QMD (Queue Meta Data 05_00, clcec0qmd.h): tinygrad's Blackwell
/// template, without a release (a host semaphore after the batch says it
/// is done). For a kernel without shared memory of its own, Galaxy's
/// words exactly (the tests compare them).
pub fn build(q: *[QMD_WORDS]u32, s: Shape) Error!void {
    // (CUDA's limits: a CTA of up to 1024 threads, z up to 64; grids of
    // 2^31 - 1 by 65535 by 65535; 255 registers)
    if (s.block[0] == 0 or s.block[1] == 0 or s.block[2] == 0 or s.block[0] > 1024 or s.block[1] > 1024 or s.block[2] > 64 or
        @as(u64, s.block[0]) * s.block[1] * s.block[2] > 1024) return error.OutOfRange;
    if (s.grid[0] == 0 or s.grid[1] == 0 or s.grid[2] == 0 or s.grid[0] > 0x7fff_ffff or s.grid[1] > 0xffff or s.grid[2] > 0xffff) return error.OutOfRange;
    if (s.registers == 0 or s.registers > 255) return error.OutOfRange;
    if (s.local_bytes & 0xf != 0 or s.local_bytes >> 4 > 0xffff) return error.OutOfRange;
    if (s.prog_va & 0xff != 0 or s.cbuf_va & 0x3f != 0) return error.OutOfRange;
    const shared = try sharedTotal(s.shared_bytes);
    const cfg = try smConfig(shared);
    @memset(q, 0);
    put(q, F.QMD_GROUP_ID, 0x3f);
    put(q, F.QMD_TYPE, QMD_TYPE_GRID_CTA);
    put(q, F.SASS_VERSION, s.sass);
    put(q, F.API_VISIBLE_CALL_LIMIT, 1); // NO_CHECK
    put(q, F.SAMPLER_INDEX, 1); // VIA_HEADER_INDEX
    put(q, F.QMD_MAJOR_VERSION, 5); // (minor 0)
    put(q, F.INVALIDATES, 0xf);
    put(q, F.CWD_MEMBAR_TYPE, CWD_MEMBAR_L1_SYSMEMBAR);
    put(q, F.PROGRAM_ADDRESS_LOWER_SHIFTED4, (s.prog_va >> 4) & 0xffff_ffff);
    put(q, F.PROGRAM_ADDRESS_UPPER_SHIFTED4, s.prog_va >> 36);
    put(q, F.PROGRAM_PREFETCH_SIZE, @min(s.prog_bytes >> 8, 0x1ff));
    put(q, F.CTA_THREAD_DIMENSION0, s.block[0]);
    put(q, F.CTA_THREAD_DIMENSION1, s.block[1]);
    put(q, F.CTA_THREAD_DIMENSION2, s.block[2]);
    put(q, F.REGISTER_COUNT, s.registers);
    put(q, F.BARRIER_COUNT, 1);
    put(q, F.SHARED_MEMORY_SIZE_SHIFTED7, shared >> 7);
    put(q, F.MIN_SM_CONFIG_SHARED_MEM_SIZE, cfg);
    put(q, F.MAX_SM_CONFIG_SHARED_MEM_SIZE, SM_CONFIG_MAX);
    put(q, F.TARGET_SM_CONFIG_SHARED_MEM_SIZE, cfg);
    put(q, F.SHADER_LOCAL_MEMORY_HIGH_SIZE_SHIFTED4, s.local_bytes >> 4);
    put(q, F.GRID_WIDTH, s.grid[0]);
    put(q, F.GRID_HEIGHT, s.grid[1]);
    put(q, F.GRID_DEPTH, s.grid[2]);
    put(q, F.cbAddrLower(0), (s.cbuf_va >> 6) & 0xffff_ffff);
    put(q, F.cbAddrUpper(0), s.cbuf_va >> 38);
    put(q, F.cbSize(0), CBUF0_BYTES >> 4);
    put(q, F.cbValid(0), 1);
    put(q, F.cbInvalidate(0), 1);
    put(q, F.PROGRAM_PREFETCH_ADDR_LOWER_SHIFTED, (s.prog_va >> 8) & 0xffff_ffff);
    put(q, F.PROGRAM_PREFETCH_ADDR_UPPER_SHIFTED, s.prog_va >> 40);
}

/// A release when the grid is done: `payload` (32 bits) written to `va`
/// (RELEASE0, one word). Galaxy releases with a host semaphore after a
/// batch instead (push.sig); this is tinygrad's way, per launch.
pub fn release(q: *[QMD_WORDS]u32, va: u64, payload: u32) void {
    put(q, F.RELEASE_ENABLE0, 1);
    put(q, F.RELEASE_STRUCTURE_SIZE0, 1); // SEMAPHORE_ONE_WORD
    put(q, F.RELEASE_SEMAPHORE0_ADDR_LOWER, va & 0xffff_ffff);
    put(q, F.RELEASE_SEMAPHORE0_ADDR_UPPER, va >> 32);
    put(q, F.RELEASE_SEMAPHORE0_PAYLOAD_LOWER, payload);
}

// ── Reading one back ────────────────────────────────────────────────────────

pub const ConstBuf = struct { va: u64 = 0, bytes: u32 = 0, valid: bool = false };

pub const Release = struct {
    va: u64,
    payload: u64,
    /// 0: four words (the payload, then a 64-bit timestamp), 1: one word,
    /// 2: two words (a 64-bit payload).
    structure: u2,
};

/// What a QMD says, as the compute engine reads it.
pub const Launch = struct {
    prog_va: u64,
    prefetch_bytes: u32,
    block: [3]u32,
    grid: [3]u32,
    registers: u32,
    barriers: u32,
    shared_bytes: u32,
    sm_config: struct { min: u32, max: u32, target: u32 },
    local_low: u32,
    local_high: u32,
    sass: u32,
    cbufs: [CBUFS]ConstBuf,
    release: ?Release,
};

pub fn decode(q: *const [QMD_WORDS]u32) Error!Launch {
    if (at(q, F.QMD_MAJOR_VERSION) != 5 or at(q, F.QMD_MINOR_VERSION) != 0 or at(q, F.QMD_TYPE) != QMD_TYPE_GRID_CTA) return error.BadQmd;
    var l = Launch{
        .prog_va = (at(q, F.PROGRAM_ADDRESS_UPPER_SHIFTED4) << 36) | (at(q, F.PROGRAM_ADDRESS_LOWER_SHIFTED4) << 4),
        .prefetch_bytes = @intCast(at(q, F.PROGRAM_PREFETCH_SIZE) << 8),
        .block = .{ @intCast(at(q, F.CTA_THREAD_DIMENSION0)), @intCast(at(q, F.CTA_THREAD_DIMENSION1)), @intCast(at(q, F.CTA_THREAD_DIMENSION2)) },
        .grid = .{ @intCast(at(q, F.GRID_WIDTH)), @intCast(at(q, F.GRID_HEIGHT)), @intCast(at(q, F.GRID_DEPTH)) },
        .registers = @intCast(at(q, F.REGISTER_COUNT)),
        .barriers = @intCast(at(q, F.BARRIER_COUNT)),
        .shared_bytes = @intCast(at(q, F.SHARED_MEMORY_SIZE_SHIFTED7) << 7),
        .sm_config = .{
            .min = @intCast(at(q, F.MIN_SM_CONFIG_SHARED_MEM_SIZE)),
            .max = @intCast(at(q, F.MAX_SM_CONFIG_SHARED_MEM_SIZE)),
            .target = @intCast(at(q, F.TARGET_SM_CONFIG_SHARED_MEM_SIZE)),
        },
        .local_low = @intCast(at(q, F.SHADER_LOCAL_MEMORY_LOW_SIZE_SHIFTED4) << 4),
        .local_high = @intCast(at(q, F.SHADER_LOCAL_MEMORY_HIGH_SIZE_SHIFTED4) << 4),
        .sass = @intCast(at(q, F.SASS_VERSION)),
        .cbufs = undefined,
        .release = null,
    };
    for (0..CBUFS) |k| {
        const i: u32 = @intCast(k);
        l.cbufs[k] = .{
            .va = (at(q, F.cbAddrUpper(i)) << 38) | (at(q, F.cbAddrLower(i)) << 6),
            .bytes = @intCast(at(q, F.cbSize(i)) << 4),
            .valid = at(q, F.cbValid(i)) != 0,
        };
    }
    if (at(q, F.RELEASE_ENABLE0) != 0) {
        const structure: u2 = @intCast(at(q, F.RELEASE_STRUCTURE_SIZE0));
        const wide = at(q, F.RELEASE_PAYLOAD64B0) != 0 or structure != 1;
        l.release = .{
            .va = (at(q, F.RELEASE_SEMAPHORE0_ADDR_UPPER) << 32) | at(q, F.RELEASE_SEMAPHORE0_ADDR_LOWER),
            .payload = at(q, F.RELEASE_SEMAPHORE0_PAYLOAD_LOWER) | (if (wide) at(q, F.RELEASE_SEMAPHORE0_PAYLOAD_UPPER) << 32 else 0),
            .structure = structure,
        };
    }
    return l;
}

// ── Constant buffer 0 ───────────────────────────────────────────────────────

/// Constant buffer 0 as CUDA kernels read it on Blackwell: tinygrad's
/// shared and local windows (words 188..191), the block's size (216..218,
/// what %ntid reads), the grid's (220..222, %nctaid), the stack's top
/// (223), then the parameters (from 0x380).
pub fn cbuf0(c: *[CBUF0_WORDS]u32, grid: [3]u32, block: [3]u32, params: []const u8) Error!void {
    if (params.len > MAX_PARAMS) return error.TooManyParams;
    @memset(c, 0);
    c[188] = @truncate(SHARED_WINDOW);
    c[189] = @truncate(SHARED_WINDOW >> 32);
    c[190] = @truncate(LOCAL_WINDOW);
    c[191] = @truncate(LOCAL_WINDOW >> 32);
    c[CB_BLOCK / 4 ..][0..3].* = block;
    c[CB_GRID / 4 ..][0..3].* = grid;
    c[CB_STACK_TOP / 4] = STACK_TOP;
    @memcpy(std.mem.sliceAsBytes(c[DRIVER_WORDS..])[0..params.len], params);
}

// ── Local memory ────────────────────────────────────────────────────────────

/// Local memory's sizes, tinygrad's: a thread's stack plus CUDA's 0x240
/// above it, to 32 bytes; a warp's, to 0x200; a TPC's, for every warp its
/// SMs hold, to 32 KiB; then every TPC the design has, to 128 KiB.
pub const LocalSize = struct { per_thread: u32, per_tpc: u64, total: u64 };

pub fn localSize(stack: u32, warps_per_sm: u32, sms_per_tpc: u32, tpcs: u32) LocalSize {
    const per_thread: u32 = @intCast(alignUp(@as(u64, stack) + STACK_RESERVED, 32));
    const per_tpc = perTpc(per_thread, warps_per_sm, sms_per_tpc);
    return .{ .per_thread = per_thread, .per_tpc = per_tpc, .total = alignUp(per_tpc * tpcs, 0x20000) };
}

/// A TPC's local memory for `per_thread` bytes a thread (what
/// SET_SHADER_LOCAL_MEMORY_NON_THROTTLED must give, at least).
pub fn perTpc(per_thread: u32, warps_per_sm: u32, sms_per_tpc: u32) u64 {
    return alignUp(alignUp(@as(u64, per_thread) * 32, 0x200) * warps_per_sm * sms_per_tpc, 0x8000);
}

fn alignUp(v: u64, a: u64) u64 {
    return (v + a - 1) / a * a;
}

fn alignUp32(v: u32, a: u32) u32 {
    return (v + a - 1) / a * a;
}

// ── Host tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

/// Galaxy's M4 kernel: 8 registers, no stack, no parameters.
const M4_REGISTERS = 8;

test "M4's QMD, word by word from clcec0qmd.h's bit ranges (Galaxy's nv_chan test)" {
    var q: [QMD_WORDS]u32 = undefined;
    try build(&q, .{
        .prog_va = 0x20_0004_0000, // (galaxy: SYS_VA + CODE_OFF)
        .prog_bytes = 0x180,
        .cbuf_va = 0x20_0003_0200, // (SYS_VA + QMD_OFF + CBUF0_IN_SLOT)
        .registers = M4_REGISTERS,
        .block = .{ 32, 1, 1 },
    });
    var want = [_]u32{0} ** QMD_WORDS;
    want[4] = (0x3f << 16) | (2 << 23); // group id 149:144, type 153:151
    want[14] = 0xa4 | (1 << 8) | (1 << 9) | (5 << 20) | (0xf << 24); // SASS, call limit, sampler, major 5, invalidates
    want[19] = 1 << 16; // CWD_MEMBAR_TYPE 625:624
    want[32] = 0x0000_4000; // program >> 4, low
    want[33] = 0x2 | (1 << 21); // program >> 4, high; prefetch size 0x180 >> 8
    want[34] = 32 | (1 << 16); // CTA 32 x 1
    want[35] = 1 | (8 << 8) | (1 << 17); // x 1; 8 registers; 1 barrier
    want[36] = 8 | (9 << 11) | (0x1a << 17) | (9 << 23); // shared 0x400 >> 7; SM config min, max, target
    want[39] = 1; // grid 1 x 1 x 1
    want[40] = 1;
    want[41] = 1;
    want[42] = 0x8000_0c08; // constant buffer 0 >> 6
    want[43] = 0x40 << 19; // its size, 0x400 >> 4
    want[58] = 1 | (1 << 3); // valid, invalidate
    want[59] = 0x2000_0400; // program >> 8 (prefetch)
    try testing.expectEqualSlices(u32, &want, &q);
}

test "a QMD's grid, block and local memory (Galaxy's nv_chan test)" {
    var q: [QMD_WORDS]u32 = undefined;
    try build(&q, .{
        .prog_va = 0x20_0004_2000,
        .prog_bytes = 0x600,
        .cbuf_va = 0x20_0003_0a00,
        .registers = 26,
        .grid = .{ 32, 32, 1 },
        .block = .{ 16, 16, 1 },
        .local_bytes = 0x280,
    });
    try testing.expectEqual(@as(u32, 16 | (16 << 16)), q[34]); // CTA 16 x 16
    try testing.expectEqual(@as(u32, 1 | (26 << 8) | (1 << 17)), q[35]); // x 1; 26 registers
    try testing.expectEqual(@as(u32, 0x28 << 16), q[37]); // local memory 0x280 >> 4, high (1215:1200)
    try testing.expectEqual(@as(u32, 32), q[39]); // grid 32 x 32 x 1
    try testing.expectEqual(@as(u32, 32), q[40]);
    try testing.expectEqual(@as(u32, 1), q[41]);
    try testing.expectEqual(@as(u32, 0x2 | (6 << 21)), q[33]); // program >> 4, high; prefetch size 6 (0x600 >> 8)
}

test "shared memory: the reserved 1 KiB, the kernel's own, the SM's split" {
    try testing.expectEqual(@as(u32, 0x400), try sharedTotal(0));
    try testing.expectEqual(@as(u32, 0x480), try sharedTotal(1)); // (to 128 bytes)
    try testing.expectEqual(@as(u32, 9), try smConfig(0x400)); // 32 KiB: 32 / 4 + 1
    try testing.expectEqual(@as(u32, 9), try smConfig(32 * 1024));
    try testing.expectEqual(@as(u32, 17), try smConfig(32 * 1024 + 1)); // 64 KiB
    try testing.expectEqual(@as(u32, 0x1a), try smConfig(MAX_SHARED)); // 100 KiB
    try testing.expectEqual(@as(u32, 100 * 1024), smConfigBytes(0x1a));
    try testing.expectError(error.OutOfRange, sharedTotal(MAX_SHARED));
    var q: [QMD_WORDS]u32 = undefined;
    try build(&q, .{ .prog_va = 0x1000, .prog_bytes = 0x100, .cbuf_va = 0x2000, .registers = 32, .block = .{ 256, 1, 1 }, .shared_bytes = 48 * 1024 });
    const l = try decode(&q);
    try testing.expectEqual(@as(u32, 0x400 + 48 * 1024), l.shared_bytes);
    try testing.expectEqual(@as(u32, 17), l.sm_config.min);
    try testing.expectEqual(@as(u32, 17), l.sm_config.target);
    try testing.expectEqual(@as(u32, 0x1a), l.sm_config.max);
}

test "a QMD decoded: what was built, and a release" {
    var q: [QMD_WORDS]u32 = undefined;
    try build(&q, .{
        .prog_va = 0x10_2345_6700,
        .prog_bytes = 0x900,
        .cbuf_va = 0x20_0003_0a40,
        .registers = 36,
        .grid = .{ 70000, 3, 2 },
        .block = .{ 8, 4, 2 },
        .local_bytes = 0x280,
    });
    var l = try decode(&q);
    try testing.expectEqual(@as(u64, 0x10_2345_6700), l.prog_va);
    try testing.expectEqual(@as(u32, 0x900), l.prefetch_bytes);
    try testing.expectEqual([3]u32{ 8, 4, 2 }, l.block);
    try testing.expectEqual([3]u32{ 70000, 3, 2 }, l.grid);
    try testing.expectEqual(@as(u32, 36), l.registers);
    try testing.expectEqual(@as(u32, 0x280), l.local_high);
    try testing.expectEqual(@as(u32, 0), l.local_low);
    try testing.expectEqual(SASS_SM120, l.sass);
    try testing.expectEqual(ConstBuf{ .va = 0x20_0003_0a40, .bytes = CBUF0_BYTES, .valid = true }, l.cbufs[0]);
    try testing.expect(!l.cbufs[1].valid);
    try testing.expectEqual(@as(?Release, null), l.release);
    release(&q, 0x20_0002_0010, 77);
    l = try decode(&q);
    try testing.expectEqual(Release{ .va = 0x20_0002_0010, .payload = 77, .structure = 1 }, l.release.?);
    // what the engine does not take
    q[14] &= ~@as(u32, 0xf << 20);
    try testing.expectError(error.BadQmd, decode(&q));
}

test "a QMD's limits are errors, not wrong bits" {
    var q: [QMD_WORDS]u32 = undefined;
    const ok = Shape{ .prog_va = 0x1000, .prog_bytes = 0x100, .cbuf_va = 0x2000, .registers = 8 };
    var s = ok;
    s.block = .{ 1024, 2, 1 };
    try testing.expectError(error.OutOfRange, build(&q, s));
    s = ok;
    s.block = .{ 0, 1, 1 };
    try testing.expectError(error.OutOfRange, build(&q, s));
    s = ok;
    s.registers = 256;
    try testing.expectError(error.OutOfRange, build(&q, s));
    s = ok;
    s.local_bytes = 0x288; // (not 16-byte units)
    try testing.expectError(error.OutOfRange, build(&q, s));
    s = ok;
    s.prog_va = 0x1080; // (the prefetcher's 256 bytes)
    try testing.expectError(error.OutOfRange, build(&q, s));
    s = ok;
    s.shared_bytes = 100 * 1024;
    try testing.expectError(error.OutOfRange, build(&q, s));
}

test "constant buffer 0, local memory's sizes, the SASS version (Galaxy's nv_chan test)" {
    var c: [CBUF0_WORDS]u32 = undefined;
    const params = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12 };
    try cbuf0(&c, .{ 32, 32, 1 }, .{ 16, 16, 1 }, &params);
    try testing.expectEqual(@as(u32, 0), c[0]);
    try testing.expectEqual([4]u32{ 0, 0x7294, 0, 0x7293 }, c[188..192].*); // the windows
    try testing.expectEqual([3]u32{ 16, 16, 1 }, c[216..219].*); // 0x360: %ntid
    try testing.expectEqual(@as(u32, 0), c[219]);
    try testing.expectEqual([3]u32{ 32, 32, 1 }, c[220..223].*); // 0x370: %nctaid
    try testing.expectEqual(@as(u32, 0xfffdc0), c[223]); // 0x37c: the stack's top
    try testing.expectEqual([3]u32{ 0x0403_0201, 0x0807_0605, 0x0c0b_0a09 }, c[224..227].*); // 0x380: the parameters
    var big: [MAX_PARAMS + 1]u8 = undefined;
    try testing.expectError(error.TooManyParams, cbuf0(&c, .{ 1, 1, 1 }, .{ 1, 1, 1 }, &big));
    // (stack 64, 48 warps an SM, 2 SMs a TPC, 3 GPCs of 8 TPCs)
    const s = localSize(64, 48, 2, 24);
    try testing.expectEqual(@as(u32, 0x280), s.per_thread);
    try testing.expectEqual(@as(u64, 0x1e_0000), s.per_tpc);
    try testing.expectEqual(@as(u64, 0x2d0_0000), s.total);
    try testing.expectEqual(@as(u32, 0xa4), sassOf(0xa04));
    try testing.expectEqual(@as(u32, 0x90), sassOf(0x900));
}

test "bit fields: set and get agree, across words" {
    var q = [_]u32{0} ** QMD_WORDS;
    set(&q, 1076, 1056, 0x1f_ffff);
    try testing.expectEqual(@as(u64, 0x1f_ffff), get(&q, 1076, 1056));
    set(&q, 1085, 1077, 0x155);
    try testing.expectEqual(@as(u64, 0x155), get(&q, 1085, 1077));
    try testing.expectEqual(@as(u64, 0x1f_ffff), get(&q, 1076, 1056));
    set(&q, 1919, 1888, 0xdead_beef);
    try testing.expectEqual(@as(u32, 0xdead_beef), q[59]);
}
