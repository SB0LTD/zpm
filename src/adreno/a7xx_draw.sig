//! @zpm/adreno a7xx_draw — command streams that draw with the A7xx's
//! graphics pipeline: rectangles through the rasterizer, shaded by a vertex
//! and a fragment program, textures through the texture units, blending in
//! the render backend. The target is plain memory ("sysmem", or direct,
//! rendering: no tiling pass, no GMEM).
//!
//! What is here is what a compositor needs: one color target, no depth or
//! stencil, one sample a pixel, rectangles given by two corners
//! (DI_PT_RECTLIST), positions in window pixels (no viewport transform, no
//! clipping, no perspective), up to MAX_TEXTURES textures.
//!
//! The register writes follow Mesa's turnip, which draws its own clears and
//! blits this way: tu_clear_blit.cc's r3d_* functions, and tu_cmd_buffer.cc's
//! tu6_init_static_regs, tu6_sysmem_render_begin and the functions they
//! call, with the register database (a6xx.xml, adreno_pm4.xml) and the
//! X1-45's device entry. All of it used as documentation only; each block
//! below names the function it follows. The values were then compared with
//! what turnip itself emits as an X1-45 (its command streams dumped with no
//! hardware, through Mesa's no-op DRM shim, and decoded by cffdump): a clear
//! rectangle, a filtered blit and a textured, blended draw.
//!
//! Allocation-free: streams are built into caller memory (a7xx.Stream).

const std = @import("std");
const ir3_asm = @import("ir3_asm.sig");
const a7xx = @import("a7xx.sig");

pub const Stream = a7xx.Stream;
const INVALID_REG: u32 = ir3_asm.INVALID_REG;

// ── PM4 opcodes and their fields (adreno_pm4.xml) ───────────────────────────

pub const CP_WAIT_FOR_ME = 0x13;
pub const CP_SKIP_IB2_ENABLE_GLOBAL = 0x1d;
pub const CP_LOAD_STATE6_GEOM = 0x32;
pub const CP_DRAW_INDX_OFFSET = 0x38;
pub const CP_SET_MODE = 0x63;
pub const CP_SET_VISIBILITY_OVERRIDE = 0x64;

pub const RM6_DIRECT_RENDER = 1;

pub const DI_PT_RECTLIST = 8;
pub const DI_SRC_SEL_AUTO_INDEX = 2;

pub const SB6_FS_TEX = 0x4;
pub const SB6_VS_SHADER = 0x8;
pub const SB6_FS_SHADER = 0xc;

// Events (vgt_event_type, A7XX).
pub const DUMMY_EVENT = 0x01;
pub const CCU_INVALIDATE_DEPTH = 0x18;
pub const CCU_INVALIDATE_COLOR = 0x19;
pub const CCU_CLEAN_DEPTH = 0x20;
pub const CCU_CLEAN_COLOR = 0x21;
pub const LRZ_CACHE_FLUSH = 0x26;
pub const LRZ_CACHE_INVALIDATE = 0x28;

// ── Registers (a6xx.xml, the A7XX variants; dword offsets) ──────────────────

pub const GRAS_CL_CNTL = 0x8000;
pub const GRAS_CL_VS_CLIP_CULL_DISTANCE = 0x8001;
pub const GRAS_CL_ARRAY_SIZE = 0x8004;
pub const GRAS_CL_INTERP_CNTL = 0x8005;
pub const GRAS_LRZ_CB_CNTL = 0x8007;
pub const GRAS_BIN_FOVEAT = 0x8008;
pub const GRAS_CL_VIEWPORT_ZCLAMP = 0x8070;
pub const GRAS_SU_CNTL = 0x8090;
pub const GRAS_SU_DEPTH_PLANE_CNTL = 0x8094;
pub const GRAS_SU_DEPTH_BUFFER_INFO = 0x8098;
pub const GRAS_SU_CONSERVATIVE_RAS_CNTL = 0x8099;
pub const GRAS_SU_VS_SIV_CNTL = 0x809b;
pub const GRAS_SC_CNTL = 0x80a0;
pub const GRAS_SC_BIN_CNTL = 0x80a1;
pub const GRAS_SC_RAS_MSAA_CNTL = 0x80a2;
pub const GRAS_SC_DEST_MSAA_CNTL = 0x80a3;
pub const GRAS_SC_SCREEN_SCISSOR_CNTL = 0x80af;
pub const GRAS_SC_SCREEN_SCISSOR_TL = 0x80b0;
pub const GRAS_SC_SCREEN_SCISSOR_BR = 0x80b1;
pub const GRAS_SC_VIEWPORT_SCISSOR_TL = 0x80d0;
pub const GRAS_SC_VIEWPORT_SCISSOR_BR = 0x80d1;
pub const GRAS_SC_WINDOW_SCISSOR_TL = 0x80f0;
pub const GRAS_SC_WINDOW_SCISSOR_BR = 0x80f1;
pub const GRAS_VRS_CONFIG = 0x80f4;
pub const GRAS_QUALITY_BUFFER_INFO = 0x80f5;
pub const GRAS_QUALITY_BUFFER_BASE = 0x80f8;
pub const GRAS_QUALITY_BUFFER_PITCH = 0x80fa;
pub const GRAS_LRZ_CNTL = 0x8100;
pub const GRAS_LRZ_PS_INPUT_CNTL = 0x8101;
pub const GRAS_LRZ_MRT_BUFFER_INFO_0 = 0x8102;
pub const GRAS_LRZ_BUFFER_BASE = 0x8103;
pub const GRAS_LRZ_BUFFER_PITCH = 0x8105;
pub const GRAS_LRZ_FAST_CLEAR_BUFFER_BASE = 0x8106;
pub const GRAS_LRZ_PS_SAMPLEFREQ_CNTL = 0x8109;
pub const GRAS_LRZ_CNTL2 = 0x810b;
pub const GRAS_MODE_CNTL = 0x8110;
pub const GRAS_LRZ_DEPTH_BUFFER_INFO = 0x8113;
pub const GRAS_SU_DEPTH_CNTL = 0x8114;
pub const GRAS_SU_STENCIL_CNTL = 0x8115;
pub const GRAS_SU_RENDER_CNTL = 0x8116;
pub const GRAS_LRZ_QUALITY_LOOKUP_TABLE = 0x8120;
pub const GRAS_A2D_SCISSOR_TL = 0x840a;
pub const GRAS_A2D_SCISSOR_BR = 0x840b;

pub const RB_CNTL = 0x8800;
pub const RB_RENDER_CNTL = 0x8801;
pub const RB_RAS_MSAA_CNTL = 0x8802;
pub const RB_DEST_MSAA_CNTL = 0x8803;
pub const RB_INTERP_CNTL = 0x8809;
pub const RB_PS_INPUT_CNTL = 0x880a;
pub const RB_PS_OUTPUT_CNTL = 0x880b;
pub const RB_PS_MRT_CNTL = 0x880c;
pub const RB_PS_OUTPUT_MASK = 0x880d;
pub const RB_DITHER_CNTL = 0x880e;
pub const RB_SRGB_CNTL = 0x880f;
pub const RB_PS_SAMPLEFREQ_CNTL = 0x8810;
pub const RB_MODE_CNTL = 0x8811;
pub const RB_BUFFER_CNTL = 0x8812;
pub const RB_UNKNOWN_8818 = 0x8818;
pub const RB_MRT_CONTROL = 0x8820;
pub const RB_MRT_BLEND_CONTROL = 0x8821;
pub const RB_MRT_BUF_INFO = 0x8822;
pub const RB_MRT_PITCH = 0x8823;
pub const RB_MRT_ARRAY_PITCH = 0x8824;
pub const RB_MRT_BASE = 0x8825;
pub const RB_MRT_BASE_GMEM = 0x8827;
pub const RB_ALPHA_TEST_CNTL = 0x8864;
pub const RB_BLEND_CNTL = 0x8865;
pub const RB_DEPTH_PLANE_CNTL = 0x8870;
pub const RB_DEPTH_CNTL = 0x8871;
pub const RB_DEPTH_BUFFER_INFO = 0x8872;
pub const RB_DEPTH_BOUND_MIN = 0x8878;
pub const RB_STENCIL_CNTL = 0x8880;
pub const RB_STENCIL_BUFFER_INFO = 0x8881;
pub const RB_STENCIL_REF_CNTL = 0x8887;
pub const RB_STENCIL_MASK = 0x8888;
pub const RB_STENCIL_WRITE_MASK = 0x8889;
pub const RB_WINDOW_OFFSET = 0x8890;
pub const RB_SAMPLE_COUNTER_CNTL = 0x8891;
pub const RB_LRZ_CNTL = 0x8898;
pub const RB_VIEWPORT_ZCLAMP_MIN = 0x88c0;
pub const RB_RESOLVE_CNTL_3 = 0x88d3;
pub const RB_RESOLVE_WINDOW_OFFSET = 0x88d4;
pub const RB_CLEAR_TARGET = 0x88e4;
pub const RB_CCU_CACHE_CNTL = 0x88e5;
pub const RB_VRS_CONFIG = 0x88f4;
pub const RB_BIN_FOVEAT = 0x88f5;
pub const RB_COLOR_FLAG_BUFFER = 0x8903;
pub const RB_A2D_DEST_BUFFER_ARRAY_PITCH = 0x8c34;
pub const RB_CCU_CNTL = 0x8e07;
pub const RB_UNKNOWN_8E09 = 0x8e09;

pub const VPC_VS_CLIP_CULL_CNTL = 0x9101;
pub const VPC_VS_SIV_CNTL = 0x9104;
pub const VPC_RAST_STREAM_CNTL = 0x9107;
pub const VPC_RAST_CNTL = 0x9108;
pub const VPC_PC_CNTL = 0x9109;
pub const VPC_STEREO_RENDERING_VIEWMASK = 0x910b;
pub const VPC_STEREO_RENDERING_CNTL = 0x910c;
pub const VPC_VARYING_INTERP_MODE = 0x9200;
pub const VPC_VARYING_REPLACE_MODE = 0x9208;
pub const VPC_VARYING_LM_TRANSFER_CNTL_DISABLE = 0x9212;
pub const VPC_SO_MAPPING_WPTR = 0x9216;
pub const VPC_REPLACE_MODE_CNTL = 0x9236;
pub const VPC_ROTATION_CNTL = 0x9300;
pub const VPC_VS_CNTL = 0x9301;
pub const VPC_PS_CNTL = 0x9304;
pub const VPC_SO_CNTL = 0x9305;
pub const VPC_SO_OVERRIDE = 0x9306;
pub const VPC_PS_RAST_CNTL = 0x9307;
pub const VPC_UNKNOWN_CNTL = 0x930a;
pub const VPC_VS_CLIP_CULL_CNTL_V2 = 0x9311;
pub const VPC_VS_SIV_CNTL_V2 = 0x9314;
pub const VPC_RAST_STREAM_CNTL_V2 = 0x9317;
pub const VPC_LB_MODE_CNTL = 0x9602;

pub const PC_PS_CNTL = 0x9806;
pub const PC_DGEN_SO_CNTL = 0x9808;
pub const PC_DGEN_RAST_CNTL = 0x9809;
pub const PC_DGEN_SU_CONSERVATIVE_RAS_CNTL = 0x980a;
pub const PC_HS_BUFFER_SIZE = 0x9885;
pub const PC_TF_BUFFER_SIZE = 0x9886;
pub const PC_CNTL = 0x9b00;
pub const PC_VS_CNTL = 0x9b01;
pub const PC_STEREO_RENDERING_CNTL = 0x9b07;
pub const PC_CONTEXT_SWITCH_GFX_PREEMPTION_MODE = 0x9e72;

pub const VFD_CNTL_0 = 0xa000;
pub const VFD_CNTL_1 = 0xa001;
pub const VFD_CNTL_2 = 0xa002;
pub const VFD_CNTL_3 = 0xa003;
pub const VFD_CNTL_5 = 0xa005;
pub const VFD_CNTL_6 = 0xa006;
pub const VFD_RENDER_MODE = 0xa007;
pub const VFD_STEREO_RENDERING_CNTL = 0xa008;
pub const VFD_MODE_CNTL = 0xa009;
pub const VFD_INDEX_OFFSET = 0xa00e;
pub const VFD_INSTANCE_START_OFFSET = 0xa00f;

pub const SP_VS_CNTL_0 = 0xa800;
pub const SP_VS_OUTPUT_CNTL = 0xa802;
pub const SP_VS_OUTPUT_REG = 0xa803;
pub const SP_VS_VPC_DEST_REG = 0xa813;
pub const SP_VS_PROGRAM_COUNTER_OFFSET = 0xa81b;
pub const SP_VS_BASE = 0xa81c;
pub const SP_VS_PVT_MEM_PARAM = 0xa81e;
pub const SP_VS_PVT_MEM_BASE = 0xa81f;
pub const SP_VS_PVT_MEM_SIZE = 0xa821;
pub const SP_VS_CONFIG = 0xa823;
pub const SP_VS_INSTR_SIZE = 0xa824;
pub const SP_VS_PVT_MEM_STACK_OFFSET = 0xa825;
pub const SP_VS_CONST_CONFIG = 0xa827;
pub const SP_VS_VGS_CNTL = 0xa82d;
pub const SP_HS_CONFIG = 0xa83b;
pub const SP_HS_CONST_CONFIG = 0xa83f;
pub const SP_DS_CONFIG = 0xa863;
pub const SP_DS_CONST_CONFIG = 0xa867;
pub const SP_GS_CONFIG = 0xa894;
pub const SP_GS_CONST_CONFIG = 0xa898;
pub const SP_PS_CNTL_0 = 0xa980;
pub const SP_PS_PROGRAM_COUNTER_OFFSET = 0xa982;
pub const SP_PS_BASE = 0xa983;
pub const SP_PS_PVT_MEM_PARAM = 0xa985;
pub const SP_PS_PVT_MEM_BASE = 0xa986;
pub const SP_PS_PVT_MEM_SIZE = 0xa988;
pub const SP_BLEND_CNTL = 0xa989;
pub const SP_SRGB_CNTL = 0xa98a;
pub const SP_PS_OUTPUT_MASK = 0xa98b;
pub const SP_PS_OUTPUT_CNTL = 0xa98c;
pub const SP_PS_MRT_CNTL = 0xa98d;
pub const SP_PS_OUTPUT_REG = 0xa98e;
pub const SP_PS_MRT_REG = 0xa996;
pub const SP_PS_INITIAL_TEX_LOAD_CNTL = 0xa99e;
pub const SP_PS_INITIAL_TEX_LOAD_CMD = 0xa99f;
pub const SP_PS_INITIAL_TEX_INDEX_CMD = 0xa9a3;
pub const SP_PS_TSIZE = 0xa9a7;
pub const SP_UNKNOWN_A9A8 = 0xa9a8;
pub const SP_PS_PVT_MEM_STACK_OFFSET = 0xa9a9;
pub const SP_RENDER_CNTL = 0xa9aa;
pub const SP_DITHER_CNTL = 0xa9ac;
pub const SP_VRS_CONFIG = 0xa9ad;
pub const SP_PS_CNTL_1 = 0xa9ae;
pub const SP_PS_WAVE_CNTL = 0xa9c6;
pub const SP_LB_PARAM_LIMIT = 0xa9c7;
pub const SP_REG_PROG_ID_0 = 0xa9c8;
pub const SP_REG_PROG_ID_1 = 0xa9c9;
pub const SP_REG_PROG_ID_2 = 0xa9ca;
pub const SP_REG_PROG_ID_3 = 0xa9cb;
pub const SP_PS_SAMPLER_BASE = 0xa9e0;
pub const SP_PS_TEXMEMOBJ_BASE = 0xa9e4;
pub const SP_PS_VGS_CNTL = 0xaa01;
pub const SP_PS_OUTPUT_CONST_CNTL = 0xaa02;
pub const SP_PS_OUTPUT_CONST_MASK = 0xaa03;
pub const SP_MODE_CNTL = 0xab00;
pub const SP_PS_CONST_CONFIG = 0xab03;
pub const SP_PS_CONFIG = 0xab04;
pub const SP_PS_INSTR_SIZE = 0xab05;
pub const SP_UPDATE_CNTL = 0xab1f;
pub const SP_GFX_USIZE = 0xab20;
pub const SP_WINDOW_OFFSET = 0xab21;
pub const SP_NC_MODE_CNTL_2 = 0xae04;
pub const SP_PERFCTR_SHADER_MASK = 0xae0f;

pub const TPL1_CS_BORDER_COLOR_BASE = 0xb180;
pub const TPL1_PS_ROTATION_CNTL = 0xb182;
pub const TPL1_PS_SWIZZLE_CNTL = 0xb183;
pub const TPL1_A2D_WINDOW_OFFSET = 0xb2d1;
pub const TPL1_RAS_MSAA_CNTL = 0xb300;
pub const TPL1_DEST_MSAA_CNTL = 0xb301;
pub const TPL1_GFX_BORDER_COLOR_BASE = 0xb302;
pub const TPL1_WINDOW_OFFSET = 0xb307;
pub const TPL1_MODE_CNTL = 0xb309;
pub const TPL1_BICUBIC_WEIGHTS_TABLE = 0xb608;

// ── Formats ─────────────────────────────────────────────────────────────────

pub const FMT6_8_UNORM = 0x03;
pub const FMT6_8_8_8_8_UNORM = 0x30;
/// a3xx_color_swap: how the format's channels lie in memory.
pub const WZYX = 0;
pub const WXYZ = 1;

/// A pixel layout, by its bytes in memory.
pub const Format = enum(u8) {
    /// R, G, B, A.
    rgba8,
    /// B, G, R, A (a little-endian 0xAARRGGBB word).
    bgra8,
    /// One byte, read as (v, 0, 0, 1).
    r8,

    pub fn bytes(f: Format) u32 {
        return if (f == .r8) 1 else 4;
    }
    pub fn hw(f: Format) u32 {
        return if (f == .r8) FMT6_8_UNORM else FMT6_8_8_8_8_UNORM;
    }
    pub fn swap(f: Format) u32 {
        return if (f == .bgra8) WXYZ else WZYX;
    }
};

/// Where a pass draws: `pitch` bytes a row (a multiple of 64, as the
/// register counts it), linear, one sample a pixel.
pub const Target = struct {
    va: u64,
    width: u32,
    height: u32,
    pitch: u32,
    format: Format = .bgra8,
};

pub const Filter = enum(u8) { nearest = 0, linear = 1 };

/// A texture a fragment program samples, with unnormalized coordinates
/// (texels), clamped to its edge; one level, linear layout.
pub const Texture = struct {
    va: u64,
    width: u32,
    height: u32,
    pitch: u32,
    format: Format = .bgra8,
    filter: Filter = .linear,
    /// Its alpha reads as one whatever its bytes hold (an opaque picture
    /// whose fourth byte is not kept).
    no_alpha: bool = false,
};

pub const MAX_TEXTURES = 4;
/// Dwords of a texture's descriptor and of a sampler's.
pub const TEX_DWORDS = 16;
pub const SAMP_DWORDS = 4;
/// Bytes the descriptors of `n` textures take (samplers, then textures).
pub fn descriptorBytes(n: u32) u32 {
    return n * (TEX_DWORDS + SAMP_DWORDS) * 4;
}

// Sampler descriptor bits (A6XX_TEX_SAMP).
const TEX_CLAMP_TO_EDGE = 1;
const TEX_SAMP_1_UNNORM_COORDS = 1 << 5;
const TEX_SAMP_1_MIPFILTER_LINEAR_FAR = 1 << 6;
const TEX_2D = 1;
pub const TEX_PREFETCH_SAM = 1;

/// The descriptors of `texs` (r3d_src_common): `texs.len` samplers of
/// SAMP_DWORDS, then `texs.len` textures of TEX_DWORDS, into `out` (memory
/// the GPU reads at the address `textures` is given).
pub fn descriptors(texs: []const Texture, out: []u32) void {
    const n = texs.len;
    std.debug.assert(out.len >= n * (TEX_DWORDS + SAMP_DWORDS));
    for (texs, 0..) |t, i| {
        const s = out[i * SAMP_DWORDS ..][0..SAMP_DWORDS];
        const flt: u32 = @intFromEnum(t.filter);
        // (0x60000: set by the vendor's driver and by turnip's blits)
        s[0] = (flt << 1) | (flt << 3) | (TEX_CLAMP_TO_EDGE << 5) | (TEX_CLAMP_TO_EDGE << 8) | (TEX_CLAMP_TO_EDGE << 11) | 0x60000;
        s[1] = TEX_SAMP_1_UNNORM_COORDS | TEX_SAMP_1_MIPFILTER_LINEAR_FAR;
        s[2] = 0;
        s[3] = 0;
    }
    for (texs, 0..) |t, i| {
        const d = out[n * SAMP_DWORDS + i * TEX_DWORDS ..][0..TEX_DWORDS];
        @memset(d, 0);
        // swizzles x, y, z, w as stored (R8 then reads (v, 0, 0, 1) by the
        // format's own rule); one level; linear
        // (an opaque texture's w is the constant one)
        const swiz: u32 = (0 << 4) | (1 << 7) | (2 << 10) | (@as(u32, if (t.no_alpha) 5 else 3) << 13);
        d[0] = swiz | (t.format.hw() << 22) | (t.format.swap() << 30);
        d[1] = t.width | (t.height << 15);
        // the pitch's alignment as a power of two of 64 bytes (what a
        // smaller level's pitch would be rounded to: there is one level)
        const align_log2: u32 = if (t.pitch >= 64 and t.pitch % 64 == 0) @min(@ctz(t.pitch / 64), 15) else 0;
        d[2] = align_log2 | (t.pitch << 7) | (TEX_2D << 29);
        // the layer's size in 4 KiB
        d[3] = (std.mem.alignForward(u32, t.pitch * t.height, 4096) >> 12) & 0x7fffff;
        d[4] = @truncate(t.va);
        // depth 1
        d[5] = (@as(u32, @truncate(t.va >> 32)) & 0x1ffff) | (1 << 17);
    }
}

// ── Programs ────────────────────────────────────────────────────────────────

/// A vertex and a fragment program and how they are wired: where the
/// pipeline delivers and collects their values. Register ids are
/// number * 4 + component (r1.z is 6); INVALID_REG where unused.
pub const Program = struct {
    vs: *const ir3_asm.Kernel,
    vs_va: u64,
    fs: *const ir3_asm.Kernel,
    fs_va: u64,
    /// Vertex program: where the vertex's index arrives, where it leaves
    /// the position (four registers) and its varyings.
    vertexid_reg: u8,
    pos_reg: u8,
    vary_reg: u8 = ir3_asm.INVALID_REG,
    /// Varying components the fragment program reads (0 to 4), all from
    /// `vary_reg` on. With rectangles (two vertices), component 0 runs
    /// from the first corner's value to the second's along x, component 1
    /// along y, as turnip's blit coordinates do.
    varyings: u8 = 0,
    /// Fragment program: where the barycentrics arrive (bary.f's source),
    /// where it leaves the color (four registers).
    ij_reg: u8 = ir3_asm.INVALID_REG,
    color_reg: u8,
    /// Textures (and samplers) it samples.
    textures: u8 = 0,
    /// Where the pipeline leaves texture 0's sample at the varying
    /// coordinates before the program starts (four registers), as turnip's
    /// own blits and simple shaders get theirs: the program reads it
    /// through (sy) and has no sample instruction. INVALID_REG: none.
    prefetch_reg: u8 = ir3_asm.INVALID_REG,
};

fn xsCntl0(k: *const ir3_asm.Kernel) u32 {
    // (the field counts pairs of levels: Mesa's ir3_shader_branchstack_hw)
    const branchstack: u32 = (@min(@as(u32, k.branchstack), 64) + 1) / 2;
    return (@as(u32, k.half_regs) << 1) | (@as(u32, @max(k.full_regs, 1)) << 7) | (branchstack << 13);
}

// ── The stream ──────────────────────────────────────────────────────────────

fn event(s: *Stream, ev: u32) void {
    s.pkt(a7xx.CP_EVENT_WRITE7, &.{ev});
}

/// The CCU's caches in the GMEM while drawing to plain memory
/// (fd6_calc_gmem_cache_offsets for the X1-45: three CCUs, 256 KiB of depth
/// cache and 64 KiB of color cache each, the depth cache first).
const CCU_COLOR_OFFSET = 3 * 256 * 1024;

/// Once per stream, before any pass: the pipe, the per-GPU values and the
/// state no pass changes (tu_init_hw, tu6_init_static_regs,
/// emit_rb_ccu_cntl). `border_va` is 128 bytes of zeros the GPU can read
/// (the border colors: unused, clamp-to-edge samplers only, but the
/// registers point somewhere real).
pub fn setup(s: *Stream, border_va: u64) void {
    s.threadBr();
    event(s, CCU_INVALIDATE_COLOR);
    event(s, CCU_INVALIDATE_DEPTH);
    event(s, LRZ_CACHE_INVALIDATE);
    event(s, a7xx.CACHE_INVALIDATE7);
    s.waitForIdle();
    // every stage's state, the UAVs and the bindless bases: stale
    s.reg(SP_UPDATE_CNTL, 0x1f | (1 << 5) | (1 << 6) | (1 << 7) | (0xff << 9) | (0xff << 17));
    s.waitForIdle();
    // gmem fast clear on, concurrent resolve mode 2, unresolve full
    s.reg(RB_CCU_CNTL, (2 << 2) | (3 << 5));
    for (a7xx.x1_45_magic) |m| {
        const v = switch (m[0]) {
            // TPL1_DBG_ECO_CNTL: linear mipmaps fall back in blocks
            0xb600 => m[1] | (1 << 25),
            // TPL1_DBG_ECO_CNTL1: the X1-45's UBWC flag hint
            0xb602 => m[1] | (1 << 18),
            // SP_CHICKEN_BITS: EOLM enabled
            0xae03 => m[1] | (1 << 1),
            else => m[1],
        };
        s.reg(m[0], v);
    }
    // the shading rates' table (fd_gras_shading_rate_lut)
    s.regs(GRAS_LRZ_QUALITY_LOOKUP_TABLE, &.{ 0x09510840, 0x00000a62 });
    s.reg(SP_NC_MODE_CNTL_2, 0);
    s.reg(SP_PERFCTR_SHADER_MASK, 0x3f);
    s.reg(SP_GFX_USIZE, 0);
    s.reg(TPL1_PS_ROTATION_CNTL, 0);
    s.reg(SP_UNKNOWN_A9A8, 0);
    // constant demotion on, isam mode GL
    s.reg(SP_MODE_CNTL, 1 | (2 << 1));
    s.reg(VFD_MODE_CNTL, 1 | 2);
    s.reg(RB_MODE_CNTL, 0x10);
    s.reg(GRAS_MODE_CNTL, 2);
    s.reg(RB_UNKNOWN_8818, 0);
    s.reg(VPC_REPLACE_MODE_CNTL, 0);
    s.reg(VPC_ROTATION_CNTL, 0);
    s.reg(VPC_SO_OVERRIDE, 1);
    s.reg(TPL1_PS_SWIZZLE_CNTL, 0);
    s.reg(GRAS_SC_SCREEN_SCISSOR_CNTL, 0);
    s.reg(VPC_LB_MODE_CNTL, 0);
    s.reg(PC_CONTEXT_SWITCH_GFX_PREEMPTION_MODE, 0);
    // isam mode GL, coordinates truncated, nearest: clamp then round,
    // the destination's type from the instruction
    s.reg(TPL1_MODE_CNTL, 2 | (1 << 5) | (1 << 7));
    s.reg(SP_REG_PROG_ID_3, 0xfc);
    s.reg(VFD_RENDER_MODE, 0);
    s.reg(RB_ALPHA_TEST_CNTL, 0);
    s.reg64(TPL1_GFX_BORDER_COLOR_BASE, border_va);
    s.reg64(TPL1_CS_BORDER_COLOR_BASE, border_va);
    s.reg(RB_UNKNOWN_8E09, 7);
    s.regs(TPL1_BICUBIC_WEIGHTS_TABLE, &.{ 0, 0x3fe05ff4, 0x3fa0ebee, 0x3f5193ed, 0x3f0243f0 });
    s.reg(PC_HS_BUFFER_SIZE, 0x20000);
    s.reg(PC_TF_BUFFER_SIZE, 0x2000);
    s.reg(SP_PS_CNTL_0, 0);
    s.reg(SP_VS_CONST_CONFIG, (8 >> 2) | (1 << 8));
    // tu_init_hw_rp
    s.reg(VPC_UNKNOWN_CNTL, 0);
    s.reg(RB_A2D_DEST_BUFFER_ARRAY_PITCH, 0);
    // emit_rb_ccu_cntl, sysmem: full caches, depth at 0, color after it
    s.reg(RB_CCU_CACHE_CNTL, ((CCU_COLOR_OFFSET >> 21) << 2) | (((CCU_COLOR_OFFSET & 0x1fffff) >> 12) << 23));
}

fn xy(x: u32, y: u32) u32 {
    return x | (y << 16);
}

/// Begin drawing to `t` (tu6_sysmem_render_begin, then r3d_setup's and
/// r3d_dst_buffer's state): the target, no depth or stencil, one sample,
/// positions taken as window pixels.
pub fn begin(s: *Stream, t: Target) void {
    // tu_lrz_sysmem_begin, no depth attachment: LRZ off
    s.reg(GRAS_LRZ_CNTL, 0);
    s.reg(GRAS_LRZ_CNTL2, 0);
    s.reg64(GRAS_LRZ_BUFFER_BASE, 0);
    s.reg(GRAS_LRZ_BUFFER_PITCH, 0);
    s.reg64(GRAS_LRZ_FAST_CLEAR_BUFFER_BASE, 0);
    s.reg(GRAS_LRZ_DEPTH_BUFFER_INFO, 0);
    s.reg(GRAS_LRZ_CB_CNTL, 0);
    s.threadBr();
    // tu6_emit_window_scissor, tu6_emit_window_offset
    s.regs(GRAS_SC_WINDOW_SCISSOR_TL, &.{ xy(0, 0), xy(t.width - 1, t.height - 1) });
    s.regs(GRAS_A2D_SCISSOR_TL, &.{ xy(0, 0), xy(t.width - 1, t.height - 1) });
    s.reg(RB_WINDOW_OFFSET, 0);
    s.reg(RB_RESOLVE_WINDOW_OFFSET, 0);
    s.reg(SP_WINDOW_OFFSET, 0);
    s.reg(TPL1_WINDOW_OFFSET, 0);
    s.reg(TPL1_A2D_WINDOW_OFFSET, 0);
    // tu6_emit_bin_size: no bins, a rendering pass, buffers in sysmem,
    // LRZ feedback as the X1-45 has it (early Z, or early then late)
    s.reg(GRAS_SC_BIN_CNTL, (3 << 22) | (3 << 24));
    s.reg(RB_CNTL, (3 << 22) | (3 << 24));
    s.reg(RB_RESOLVE_CNTL_3, 0);
    // tu7_emit_sysmem_render_begin_regs
    s.reg(RB_BUFFER_CNTL, 0x3ff);
    s.reg(RB_CLEAR_TARGET, 0);
    s.pkt(a7xx.CP_SET_MARKER, &.{RM6_DIRECT_RENDER});
    s.pkt(CP_SKIP_IB2_ENABLE_GLOBAL, &.{0});
    // tu_emit_cache_flush_ccu: what an earlier pass left is written out,
    // then the color cache starts empty
    event(s, CCU_CLEAN_COLOR);
    event(s, CCU_INVALIDATE_COLOR);
    s.waitForIdle();
    s.pkt(CP_SET_VISIBILITY_OVERRIDE, &.{1});
    s.pkt(CP_SET_MODE, &.{0});
    s.reg(GRAS_BIN_FOVEAT, 0);
    s.reg(RB_BIN_FOVEAT, 0);

    // tu6_emit_zs, tu6_emit_mrt: no depth or stencil buffer; one color
    // target, the other seven none
    s.regs(RB_DEPTH_BUFFER_INFO, &.{ 0, 0, 0, 0, 0, 0 });
    s.reg(GRAS_SU_DEPTH_BUFFER_INFO, 0);
    s.reg(RB_STENCIL_BUFFER_INFO, 0);
    s.regs(RB_DEPTH_BOUND_MIN, &.{ 0, 0x3f800000 });
    s.regs(RB_VIEWPORT_ZCLAMP_MIN, &.{ 0, 0x3f800000 });
    s.regs(GRAS_CL_VIEWPORT_ZCLAMP, &.{ 0, 0x3f800000 });
    s.reg(GRAS_CL_ARRAY_SIZE, 0);
    s.regs(GRAS_QUALITY_BUFFER_INFO, &.{ 0, 0 });
    s.regs(GRAS_QUALITY_BUFFER_BASE, &.{ 0, 0, 0 });
    for (1..8) |i| {
        const at: u32 = @intCast(i * 8);
        s.regs(RB_MRT_BUF_INFO + at, &.{ 0, 0, 0, 0, 0, 0 });
        s.reg(SP_PS_MRT_REG + @as(u32, @intCast(i)), 0);
    }
    // r3d_dst_buffer
    s.regs(RB_MRT_BUF_INFO, &.{ t.format.hw() | (t.format.swap() << 13), t.pitch >> 6, (t.pitch * t.height) >> 6 });
    s.reg64(RB_MRT_BASE, t.va);
    s.reg(RB_MRT_BASE_GMEM, 0);
    s.regs(RB_COLOR_FLAG_BUFFER, &.{ 0, 0, 0 });
    s.reg(GRAS_LRZ_MRT_BUFFER_INFO_0, t.format.hw());
    s.reg(RB_RENDER_CNTL, 0);
    s.reg(GRAS_SU_RENDER_CNTL, 0);

    // r3d_setup
    s.reg(SP_PS_MRT_CNTL, 1);
    s.reg(RB_PS_MRT_CNTL, 1);
    s.reg(RB_DEPTH_PLANE_CNTL, 0);
    s.reg(RB_DEPTH_CNTL, 0);
    s.reg(GRAS_SU_DEPTH_CNTL, 0);
    s.reg(GRAS_SU_DEPTH_PLANE_CNTL, 0);
    s.reg(RB_STENCIL_CNTL, 0);
    s.reg(GRAS_SU_STENCIL_CNTL, 0);
    s.reg(RB_STENCIL_MASK, 0);
    s.reg(RB_STENCIL_WRITE_MASK, 0);
    s.reg(RB_STENCIL_REF_CNTL, 0);
    s.reg(SP_PS_MRT_REG, t.format.hw());
    s.reg(RB_SRGB_CNTL, 0);
    s.reg(SP_SRGB_CNTL, 0);
    s.reg(GRAS_LRZ_CNTL, 0);
    s.reg(RB_LRZ_CNTL, 0);
    s.reg(GRAS_LRZ_CNTL2, 0);
    s.reg(GRAS_LRZ_DEPTH_BUFFER_INFO, 0);
    s.reg(RB_VRS_CONFIG, 0);
    s.reg(SP_VRS_CONFIG, 0);
    s.reg(GRAS_VRS_CONFIG, 0);
    s.reg(GRAS_SC_CNTL, 2);
    s.reg(RB_SAMPLE_COUNTER_CNTL, 1);
    s.reg(RB_DITHER_CNTL, 0);
    s.reg(SP_DITHER_CNTL, 0);

    // r3d_common's part that no program changes
    s.reg(PC_CNTL, 0);
    s.reg(VPC_PC_CNTL, 0);
    s.reg(SP_RENDER_CNTL, 0);
    // positions are window pixels: no clipping, no viewport transform, no
    // perspective division
    s.reg(GRAS_CL_CNTL, 1 | (1 << 7) | (1 << 8) | (1 << 9));
    s.reg(GRAS_SU_CNTL, 0);
    s.reg(VPC_RAST_CNTL, 3);
    s.reg(PC_DGEN_RAST_CNTL, 3);
    s.reg(VPC_PS_RAST_CNTL, 3);
    s.reg(VPC_RAST_STREAM_CNTL, 0);
    s.reg(VPC_RAST_STREAM_CNTL_V2, 0);
    s.reg(VPC_SO_MAPPING_WPTR, 0);
    s.reg(VPC_SO_CNTL, 0);
    s.reg(PC_DGEN_SO_CNTL, 0);
    s.reg(PC_DGEN_SU_CONSERVATIVE_RAS_CNTL, 0);
    s.reg(GRAS_SU_CONSERVATIVE_RAS_CNTL, 0);
    s.regs(GRAS_SC_VIEWPORT_SCISSOR_TL, &.{ xy(0, 0), xy(0x7fff, 0x7fff) });
    scissor(s, 0, 0, t.width, t.height);
    s.regs(VFD_INDEX_OFFSET, &.{ 0, 0 });
    // tu6_emit_msaa: one sample
    s.reg(TPL1_RAS_MSAA_CNTL, 0);
    s.reg(TPL1_DEST_MSAA_CNTL, 1 << 2);
    s.reg(GRAS_SC_RAS_MSAA_CNTL, 0);
    s.reg(GRAS_SC_DEST_MSAA_CNTL, 1 << 2);
    s.reg(RB_RAS_MSAA_CNTL, 0);
    s.reg(RB_DEST_MSAA_CNTL, 1 << 2);
}

/// Draw only inside [x0, x1) x [y0, y1) (the screen scissor; a pass begins
/// with the whole target).
pub fn scissor(s: *Stream, x0: u32, y0: u32, x1: u32, y1: u32) void {
    std.debug.assert(x1 > x0 and y1 > y0);
    s.regs(GRAS_SC_SCREEN_SCISSOR_TL, &.{ xy(x0, y0), xy(x1 - 1, y1 - 1) });
}

pub const Blend = enum(u8) {
    /// The program's color replaces the pixel.
    replace,
    /// Premultiplied source over: color + pixel * (1 - color's alpha).
    over,
};

const FACTOR_ONE = 1;
const FACTOR_ONE_MINUS_SRC_ALPHA = 7;

pub fn blend(s: *Stream, b: Blend) void {
    switch (b) {
        .replace => {
            s.regs(RB_MRT_CONTROL, &.{ 0xf << 7, 0 });
            s.reg(SP_BLEND_CNTL, 0);
            s.reg(RB_BLEND_CNTL, 0xffff << 16);
        },
        .over => {
            const f: u32 = FACTOR_ONE | (FACTOR_ONE_MINUS_SRC_ALPHA << 8);
            s.regs(RB_MRT_CONTROL, &.{ 1 | 2 | (0xf << 7), f | (f << 16) });
            // (blending on target 0, each target its own blend)
            s.reg(SP_BLEND_CNTL, 1 | (1 << 8));
            s.reg(RB_BLEND_CNTL, 1 | (1 << 8) | (0xffff << 16));
        },
    }
}

/// Program the pipeline with `p` (r3d_common: tu6_emit_xs_config,
/// tu6_emit_xs, tu6_emit_vpc, tu6_emit_vs, tu6_emit_fs).
pub fn program(s: *Stream, p: *const Program) a7xx.Error!void {
    const vs = p.vs;
    const fs = p.fs;
    if (p.vs_va & 127 != 0 or p.fs_va & 127 != 0 or vs.instrlen == 0 or fs.instrlen == 0) return error.BadKernel;
    if (p.varyings > 4 or p.textures > MAX_TEXTURES) return error.BadKernel;
    const prefetch = p.prefetch_reg != ir3_asm.INVALID_REG;
    if (prefetch and (p.textures == 0 or p.varyings < 2)) return error.BadKernel;
    const vary = p.varyings != 0;
    const thread128: u32 = @intFromBool(fs.threadsize == 128);
    s.reg(SP_UPDATE_CNTL, 0x1f | (1 << 7) | (0xff << 9) | (0xff << 17));

    // tu6_emit_xs_config
    const vs_constlen = std.mem.alignForward(u32, @max(vs.constlen, 4), 4);
    const fs_constlen = std.mem.alignForward(u32, @max(fs.constlen, 4), 4);
    s.reg(SP_VS_CONST_CONFIG, (vs_constlen >> 2) | (1 << 8));
    s.reg(SP_HS_CONST_CONFIG, 0);
    s.reg(SP_DS_CONST_CONFIG, 0);
    s.reg(SP_GS_CONST_CONFIG, 0);
    s.reg(SP_PS_CONST_CONFIG, (fs_constlen >> 2) | (1 << 8));
    s.reg(SP_VS_CONFIG, 1 << 8);
    s.reg(SP_HS_CONFIG, 0);
    s.reg(SP_DS_CONFIG, 0);
    s.reg(SP_GS_CONFIG, 0);
    s.reg(SP_PS_CONFIG, (1 << 8) | (@as(u32, p.textures) << 9) | (@as(u32, p.textures) << 17));

    // tu6_emit_xs, vertex: merged registers
    s.reg(SP_VS_CNTL_0, xsCntl0(vs) | (1 << 20));
    s.reg(SP_VS_INSTR_SIZE, vs.instrlen);
    s.reg(SP_VS_PROGRAM_COUNTER_OFFSET, 0);
    s.reg64(SP_VS_BASE, p.vs_va);
    s.reg(SP_VS_PVT_MEM_PARAM, 0);
    s.reg64(SP_VS_PVT_MEM_BASE, 0);
    s.reg(SP_VS_PVT_MEM_SIZE, 0);
    s.reg(SP_VS_PVT_MEM_STACK_OFFSET, 0);
    s.reg(SP_VS_VGS_CNTL, 0);
    // fragment: varyings, the output may reuse the inputs' registers,
    // merged registers; with a prefetched sample, its level of detail
    // worked out per pixel (the pixels of a quad that are only there for
    // that stop after the prefetch: ENDOFQUAD below)
    s.reg(SP_PS_CNTL_0, xsCntl0(fs) | (thread128 << 20) | (@as(u32, @intFromBool(vary)) << 22) | (1 << 24) | (@as(u32, @intFromBool(prefetch)) << 26) | (1 << 31));
    s.reg(SP_PS_INSTR_SIZE, fs.instrlen);
    s.reg(SP_PS_PROGRAM_COUNTER_OFFSET, 0);
    s.reg64(SP_PS_BASE, p.fs_va);
    s.reg(SP_PS_PVT_MEM_PARAM, 0);
    s.reg64(SP_PS_PVT_MEM_BASE, 0);
    s.reg(SP_PS_PVT_MEM_SIZE, 0);
    s.reg(SP_PS_PVT_MEM_STACK_OFFSET, 0);
    s.reg(SP_PS_VGS_CNTL, 0);

    // tu6_emit_vpc: the varyings at locations 0.., then the position
    const nv: u32 = p.varyings;
    const pos_loc: u32 = nv;
    const stride: u32 = nv + 4;
    if (vary) {
        const mask: u32 = (@as(u32, 1) << @intCast(nv)) - 1;
        s.reg(SP_VS_OUTPUT_REG, @as(u32, p.vary_reg) | (mask << 8) | (@as(u32, p.pos_reg) << 16) | (0xf << 24));
        s.reg(SP_VS_VPC_DEST_REG, 0 | (pos_loc << 8));
    } else {
        s.reg(SP_VS_OUTPUT_REG, @as(u32, p.pos_reg) | (0xf << 8));
        s.reg(SP_VS_VPC_DEST_REG, 0);
    }
    s.reg(VPC_VS_CNTL, stride | (pos_loc << 8) | (0xff << 16));
    s.reg(VPC_VS_CLIP_CULL_CNTL, (0xff << 8) | (0xff << 16));
    s.reg(VPC_VS_CLIP_CULL_CNTL_V2, (0xff << 8) | (0xff << 16));
    s.reg(GRAS_CL_VS_CLIP_CULL_DISTANCE, 0);
    s.reg(PC_VS_CNTL, stride);
    s.reg(SP_VS_OUTPUT_CNTL, if (vary) 2 else 1);
    s.reg(VPC_VS_SIV_CNTL, 0xff | (0xff << 8) | (0xff << 16));
    s.reg(VPC_VS_SIV_CNTL_V2, 0xff | (0xff << 8) | (0xff << 16));
    s.reg(GRAS_SU_VS_SIV_CNTL, 0);
    // (r3d_common: with two vertices a rectangle, component 0 runs along
    // x and component 1 along y)
    s.reg(VPC_VARYING_INTERP_MODE, 0);
    s.reg(VPC_VARYING_REPLACE_MODE, (2 << 2) | 1);

    // tu6_emit_vs: no multiview, the vertex's index; no attributes fetched
    // (no multiview: one view, one position)
    s.reg(PC_STEREO_RENDERING_CNTL, (1 << 1) | (1 << 2));
    s.reg(VFD_STEREO_RENDERING_CNTL, (1 << 1) | (1 << 2));
    s.reg(VPC_STEREO_RENDERING_CNTL, (1 << 1) | (1 << 2));
    s.reg(VPC_STEREO_RENDERING_VIEWMASK, 0);
    s.reg(VFD_CNTL_0, 0);
    s.reg(VFD_CNTL_1, @as(u32, p.vertexid_reg) | (INVALID_REG << 8) | (INVALID_REG << 16) | (INVALID_REG << 24));
    // tu6_emit_hs, tu6_emit_ds, tu6_emit_gs: none
    s.reg(VFD_CNTL_2, INVALID_REG | (INVALID_REG << 8));
    s.regs(VFD_CNTL_3, &.{ INVALID_REG | (INVALID_REG << 8) | (INVALID_REG << 16) | (INVALID_REG << 24), INVALID_REG });
    s.reg(VFD_CNTL_5, INVALID_REG | (INVALID_REG << 8));

    // tu6_emit_fs
    s.reg(VFD_CNTL_6, 0);
    s.reg(PC_PS_CNTL, 0);
    s.reg(GRAS_MODE_CNTL, 2);
    // tu6_emit_fs_inputs: the prefetched sample, if any: texture 0 through
    // sampler 0 at varying 0 and 1, all four components
    const ij: u32 = if (vary) p.ij_reg else INVALID_REG;
    s.reg(SP_PS_INITIAL_TEX_LOAD_CNTL, @as(u32, @intFromBool(prefetch)) | (@as(u32, @intFromBool(prefetch)) << 4) | (0x1ff << 6) | (0x1ff << 16) | (@as(u32, @intFromBool(!vary)) << 3));
    if (prefetch) {
        s.reg(SP_PS_INITIAL_TEX_LOAD_CMD, (@as(u32, p.prefetch_reg) << 13) | (0xf << 19) | (TEX_PREFETCH_SAM << 26));
        s.reg(SP_PS_INITIAL_TEX_INDEX_CMD, 0);
    }
    s.regs(SP_LB_PARAM_LIMIT, &.{
        7,
        INVALID_REG | (INVALID_REG << 8) | (INVALID_REG << 16) | (INVALID_REG << 24),
        ij | (INVALID_REG << 8) | (INVALID_REG << 16) | (INVALID_REG << 24),
        INVALID_REG | (INVALID_REG << 8) | (INVALID_REG << 16) | (INVALID_REG << 24),
        INVALID_REG | (INVALID_REG << 8),
    });
    // the registers the pipeline fills: the barycentrics' pair
    s.reg(SP_PS_CNTL_1, (if (vary) @as(u32, 2) else 0) | (1 << 8) | (1 << 9));
    s.reg(SP_PS_WAVE_CNTL, thread128 | (@as(u32, @intFromBool(vary)) << 1));
    s.reg(GRAS_CL_INTERP_CNTL, @intFromBool(vary));
    s.regs(RB_INTERP_CNTL, &.{ @as(u32, @intFromBool(vary)) | (@as(u32, @intFromBool(vary)) << 10), 0 });
    s.reg(RB_PS_SAMPLEFREQ_CNTL, 0);
    s.reg(GRAS_LRZ_PS_INPUT_CNTL, 0);
    s.reg(GRAS_LRZ_PS_SAMPLEFREQ_CNTL, 0);
    const used: u32 = (@as(u32, 1) << @intCast(nv)) - 1;
    s.regs(VPC_VARYING_LM_TRANSFER_CNTL_DISABLE, &.{ ~used, 0xffff_ffff, 0xffff_ffff, 0xffff_ffff });
    // (the X1-45's rule, QCTDD08049535: the count's quarters are even)
    const nonpos: u32 = if ((nv + 3) / 4 & 1 != 0) nv + 4 else nv;
    s.reg(VPC_PS_CNTL, nonpos | (0xff << 8) | (@as(u32, @intFromBool(vary)) << 16) | (0xff << 24));
    // tu6_emit_fs_outputs: one color, in full registers
    s.reg(SP_PS_OUTPUT_CNTL, (INVALID_REG << 8) | (INVALID_REG << 16) | (INVALID_REG << 24));
    s.reg(SP_PS_OUTPUT_REG, p.color_reg);
    s.reg(SP_PS_OUTPUT_MASK, 0xf);
    s.regs(SP_PS_OUTPUT_CONST_CNTL, &.{ 0, 0 });
    s.reg(RB_PS_OUTPUT_CNTL, 0);
    s.reg(RB_PS_OUTPUT_MASK, 0xf);
}

/// The textures the fragment program samples (r3d_src_common): their
/// descriptors, written by `descriptors`, are at `desc_va`.
pub fn textures(s: *Stream, n: u32, desc_va: u64) void {
    const tex_va = desc_va + n * SAMP_DWORDS * 4;
    s.pkt(a7xx.CP_LOAD_STATE6_FRAG, &.{ (a7xx.ST6_SHADER << 14) | (a7xx.SS6_INDIRECT << 16) | (SB6_FS_TEX << 18) | (n << 22), @truncate(desc_va), @truncate(desc_va >> 32) });
    s.reg64(SP_PS_SAMPLER_BASE, desc_va);
    s.pkt(a7xx.CP_LOAD_STATE6_FRAG, &.{ (a7xx.ST6_CONSTANTS << 14) | (a7xx.SS6_INDIRECT << 16) | (SB6_FS_TEX << 18) | (n << 22), @truncate(tex_va), @truncate(tex_va >> 32) });
    s.reg64(SP_PS_TEXMEMOBJ_BASE, tex_va);
    s.reg(SP_PS_TSIZE, n);
}

fn constants(s: *Stream, op: u32, block: u32, dwords: []const u32) void {
    const units: u32 = @intCast((dwords.len + 3) / 4);
    s.emit(a7xx.pkt7(op, 3 + units * 4));
    s.emit((a7xx.ST6_CONSTANTS << 14) | (a7xx.SS6_DIRECT << 16) | (block << 18) | (units << 22));
    s.emit(0);
    s.emit(0);
    for (dwords) |v| s.emit(v);
    var pad = units * 4 - dwords.len;
    while (pad > 0) : (pad -= 1) s.emit(0);
}

/// The vertex program's constants from c0 (in the stream, as compute's:
/// the X1-45 put constants loaded from memory at the wrong offset).
pub fn vsConstants(s: *Stream, dwords: []const u32) void {
    constants(s, CP_LOAD_STATE6_GEOM, SB6_VS_SHADER, dwords);
}

/// The fragment program's constants from c0.
pub fn fsConstants(s: *Stream, dwords: []const u32) void {
    constants(s, a7xx.CP_LOAD_STATE6_FRAG, SB6_FS_SHADER, dwords);
}

/// Draw one rectangle: the vertex program runs for vertex 0 and vertex 1,
/// two opposite corners (r3d_run).
pub fn rect(s: *Stream) void {
    s.pkt(CP_DRAW_INDX_OFFSET, &.{ DI_PT_RECTLIST | (DI_SRC_SEL_AUTO_INDEX << 6), 1, 2 });
}

/// End the pass (tu6_sysmem_render_end), and bring what was drawn to
/// memory: the color cache written out, then the UCHE's.
pub fn end(s: *Stream) void {
    event(s, CCU_CLEAN_COLOR);
    s.invalidateCaches();
    s.waitForIdle();
    s.pkt(CP_SKIP_IB2_ENABLE_GLOBAL, &.{0});
    // tu_lrz_sysmem_end
    s.reg(GRAS_LRZ_CNTL, 0);
    s.reg(GRAS_LRZ_CNTL2, 0);
    event(s, LRZ_CACHE_FLUSH);
    // the render resources released: a dummy event that clears them and
    // writes 0 to the CP's on-chip slot 5 (turnip's resource-list overflow
    // flag)
    s.pkt(a7xx.CP_EVENT_WRITE7, &.{ DUMMY_EVENT | (1 << 18) | (1 << 24) | (1 << 27), 5, 0, 0 });
    event(s, CCU_CLEAN_COLOR);
    event(s, CCU_CLEAN_DEPTH);
    // (and the UCHE's own lines, for the CPU's read)
    s.cleanCaches();
    s.waitForIdle();
}

// ── Tests ───────────────────────────────────────────────────────────────────

test "descriptors: samplers first, then textures, as r3d_src_common lays them" {
    var d: [2 * (TEX_DWORDS + SAMP_DWORDS)]u32 = undefined;
    descriptors(&.{
        .{ .va = 0x1_2345_6000, .width = 640, .height = 480, .pitch = 2560, .format = .bgra8, .filter = .linear },
        .{ .va = 0x2_0000_0040, .width = 256, .height = 64, .pitch = 256, .format = .r8, .filter = .nearest },
    }, &d);
    // sampler 0: linear both ways, clamped; unnormalized coordinates
    try std.testing.expectEqual(@as(u32, (1 << 1) | (1 << 3) | (1 << 5) | (1 << 8) | (1 << 11) | 0x60000), d[0]);
    try std.testing.expectEqual(@as(u32, (1 << 5) | (1 << 6)), d[1]);
    try std.testing.expectEqual(@as(u32, (1 << 5) | (1 << 8) | (1 << 11) | 0x60000), d[4]);
    // texture 0 at dword 8: BGRA8 is the 8888 format with the WXYZ swap
    const t0 = d[8..];
    try std.testing.expectEqual(@as(u32, FMT6_8_8_8_8_UNORM), (t0[0] >> 22) & 0xff);
    try std.testing.expectEqual(@as(u32, WXYZ), t0[0] >> 30);
    try std.testing.expectEqual(@as(u32, 640 | (480 << 15)), t0[1]);
    try std.testing.expectEqual(@as(u32, 2560), (t0[2] >> 7) & 0x3fffff);
    try std.testing.expectEqual(@as(u32, 0x2345_6000), t0[4]);
    try std.testing.expectEqual(@as(u32, 1 | (1 << 17)), t0[5]);
    const t1 = d[8 + TEX_DWORDS ..];
    try std.testing.expectEqual(@as(u32, FMT6_8_UNORM), (t1[0] >> 22) & 0xff);
}
