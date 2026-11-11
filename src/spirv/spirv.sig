//! @zpm/spirv — SPIR-V compute, vertex and fragment shaders to KIR.
//!
//! The front end of Galaxy's Vulkan driver (src/vk): a GLCompute entry
//! point of a SPIR-V module becomes one KIR kernel (docs/GPU.md), which
//! zpm's backends compile for the RTX (sm_120), the Adreno (ir3) or KIR's
//! interpreter. First target: what naga (wgpu's shader compiler) emits for
//! WGSL compute shaders, and what glslang emits for simple GLSL compute.
//!
//! # What a kernel gets from its dispatch
//!
//! The kernel's bindings are the buffers its descriptors name, one KIR
//! binding per (set, binding) the entry point uses (`Info.bindings`, in
//! the module's order). Each is the whole GPU buffer under the descriptor
//! (the VkDeviceMemory); the descriptor's place in it is in the parameter
//! words:
//!
//!   word 2i     binding i's offset in its buffer (bytes)
//!   word 2i+1   binding i's range (bytes)
//!   word 2n+w   push constant word w (n = Info.n_bindings)
//!   word 2n+p+4j..  storage image j's (the j-th binding of kind
//!               storage_image): row pitch, layer (or 3D slice) pitch,
//!               width | height << 16, depth or layers (p: the push words)
//!
//! A storage image (OpTypeImage with Sampled 2, WebGPU's storage textures)
//! is a binding of its own: its linear texels in the image's memory, the
//! view's level and first layer at the binding's offset (src/vk keeps every
//! image linear). OpImageRead and OpImageWrite address texels from those
//! words; a texel outside the image reads 0 and is not written. Formats:
//! Rgba8 (unorm), R32f/i/ui, Rg32f/i/ui, Rgba32f/i/ui.
//!
//! With `Options.robust` (Vulkan's robustBufferAccess), every load and
//! store is checked against its binding's range: a load past it reads 0,
//! a store past it is dropped. OpArrayLength reads the range.
//!
//! # How the code maps
//!
//! - **Values** are lists of KIR operands, one per scalar component
//!   (vectors, matrices, arrays and structs flattened in order), as in
//!   gfxapi's GLSL generator. Constants stay immediates.
//! - **Function variables** (and Private ones) are registers, one per
//!   component. A load copies them; a store sets them. A dynamic index
//!   into one chooses among every element (a select chain).
//! - **Workgroup variables** are shared memory, 4 bytes per component.
//! - **Storage, uniform and push-constant blocks** keep the module's
//!   layout (Offset, ArrayStride, MatrixStride).
//! - **Structured control flow** becomes KIR's: a selection is an if/else,
//!   a loop a KIR loop (a branch to its merge is `brk`, to its header
//!   `cont`; a branch to the continue target emits the continue construct
//!   there, then `cont`), a switch a KIR loop its cases leave by `brk`. A
//!   `continue` from inside a switch sets a flag the code after the switch
//!   acts on. OpPhi's registers are set on each edge into its block.
//! - **Functions** are inlined (SPIR-V has no recursion). A function that
//!   may return early runs inside a KIR loop that a return leaves (through
//!   inner loops by a flag). The entry point's own return is KIR's `ret`.
//!
//! # Vertex and fragment stages
//!
//! A graphics stage is not a kernel of its own: `Gen.emitStage` emits its
//! code into the kernel gfxapi's raster is building (its vertex kernel, its
//! tile kernel), through a `StageIO`: the inputs (vertex attributes by
//! location, the varyings, built-ins) as the raster's registers, the
//! outputs (the position, the varyings, the colour of one location) as
//! registers the raster then reads. Buffers are KIR bindings after the
//! raster's own (`StageIO.buffers`), their views (offset, range) words of
//! the draw's uniform binding, as are push constants. Images and samplers
//! become texture slots (an image with its sampler, or alone) read through
//! the caller's `TexOps` (gfxapi's texture.sig in src/vk). `Resources`
//! gathers, over both stages, what the pipeline binds.
//!
//! Not yet (an error with a message, `Gen.diag`): 64-bit and 16-bit types,
//! storage images outside compute shaders and in other formats, sampled
//! images in compute shaders, gathers, binding arrays, FragDepth, subgroup operations, atomic and/or/xor and
//! compare-exchange (KIR's atomics are add, min, max and exchange),
//! pointers as values beyond function arguments (OpPtrAccessChain,
//! variable pointers), spec constant operations, stages other than
//! GLCompute, Vertex and Fragment.
//!
//! Allocation-free: every table is the caller's (`Scratch`, the kernel's
//! `kir.Storage`).

const std = @import("std");
const gpu = @import("gpu");
const kir = gpu.kir;
const V = kir.V;
const Arg = kir.Arg;
const r = kir.r;
const u = kir.u;
const f = kir.f;
const no = kir.no;

pub const Error = error{
    /// The module is malformed (or uses a form this front end does not read).
    BadSpirv,
    /// Valid SPIR-V that the front end cannot translate yet (Gen.diag says what).
    Unsupported,
    /// A table of the Scratch is full.
    TooBig,
    /// No GLCompute entry point of that name.
    NoEntryPoint,
} || kir.Error;

pub const MAGIC: u32 = 0x07230203;

pub const MAX_IDS = 1 << 16;
pub const MAX_MEMBERS = 1 << 14;
pub const MAX_ARGS = 1 << 18;
pub const MAX_BINDINGS = 32;
pub const MAX_FRAMES = 64;
pub const MAX_LAYOUT = 4096;
/// The most components a dynamically indexed function variable spans.
pub const MAX_DYNAMIC = 1024;

const NONE: u32 = 0xffff_ffff;

// ── Opcodes (the SPIR-V 1.6 grammar's numbers) ─────────────────────────────

pub const Op = struct {
    pub const nop = 0;
    pub const undef = 1;
    pub const source_continued = 2;
    pub const source = 3;
    pub const source_extension = 4;
    pub const name = 5;
    pub const member_name = 6;
    pub const string = 7;
    pub const line = 8;
    pub const extension = 10;
    pub const ext_inst_import = 11;
    pub const ext_inst = 12;
    pub const memory_model = 14;
    pub const entry_point = 15;
    pub const execution_mode = 16;
    pub const capability = 17;
    pub const type_void = 19;
    pub const type_bool = 20;
    pub const type_int = 21;
    pub const type_float = 22;
    pub const type_vector = 23;
    pub const type_matrix = 24;
    pub const type_image = 25;
    pub const type_sampler = 26;
    pub const type_sampled_image = 27;
    pub const type_array = 28;
    pub const type_runtime_array = 29;
    pub const type_struct = 30;
    pub const type_pointer = 32;
    pub const type_function = 33;
    pub const constant_true = 41;
    pub const constant_false = 42;
    pub const constant = 43;
    pub const constant_composite = 44;
    pub const constant_null = 46;
    pub const spec_constant_true = 48;
    pub const spec_constant_false = 49;
    pub const spec_constant = 50;
    pub const spec_constant_composite = 51;
    pub const spec_constant_op = 52;
    pub const function = 54;
    pub const function_parameter = 55;
    pub const function_end = 56;
    pub const function_call = 57;
    pub const variable = 59;
    pub const load = 61;
    pub const store = 62;
    pub const copy_memory = 63;
    pub const access_chain = 65;
    pub const in_bounds_access_chain = 66;
    pub const ptr_access_chain = 67;
    pub const array_length = 68;
    pub const decorate = 71;
    pub const member_decorate = 72;
    pub const decoration_group = 73;
    pub const vector_extract_dynamic = 77;
    pub const vector_insert_dynamic = 78;
    pub const vector_shuffle = 79;
    pub const composite_construct = 80;
    pub const composite_extract = 81;
    pub const composite_insert = 82;
    pub const copy_object = 83;
    pub const transpose = 84;
    pub const sampled_image = 86;
    pub const image_sample_implicit_lod = 87;
    pub const image_sample_explicit_lod = 88;
    pub const image_sample_dref_implicit_lod = 89;
    pub const image_sample_dref_explicit_lod = 90;
    pub const image_sample_proj_implicit_lod = 91;
    pub const image_sample_proj_explicit_lod = 92;
    pub const image_fetch = 95;
    pub const image_gather = 96;
    pub const image_dref_gather = 97;
    pub const image_read = 98;
    pub const image_write = 99;
    pub const image = 100;
    pub const image_query_size_lod = 103;
    pub const image_query_size = 104;
    pub const image_query_lod = 105;
    pub const image_query_levels = 106;
    pub const image_query_samples = 107;
    pub const convert_f_to_u = 109;
    pub const convert_f_to_s = 110;
    pub const convert_s_to_f = 111;
    pub const convert_u_to_f = 112;
    pub const u_convert = 113;
    pub const s_convert = 114;
    pub const f_convert = 115;
    pub const quantize_to_f16 = 116;
    pub const bitcast = 124;
    pub const s_negate = 126;
    pub const f_negate = 127;
    pub const i_add = 128;
    pub const f_add = 129;
    pub const i_sub = 130;
    pub const f_sub = 131;
    pub const i_mul = 132;
    pub const f_mul = 133;
    pub const u_div = 134;
    pub const s_div = 135;
    pub const f_div = 136;
    pub const u_mod = 137;
    pub const s_rem = 138;
    pub const s_mod = 139;
    pub const f_rem = 140;
    pub const f_mod = 141;
    pub const vector_times_scalar = 142;
    pub const matrix_times_scalar = 143;
    pub const vector_times_matrix = 144;
    pub const matrix_times_vector = 145;
    pub const matrix_times_matrix = 146;
    pub const outer_product = 147;
    pub const dot = 148;
    pub const any = 154;
    pub const all = 155;
    pub const is_nan = 156;
    pub const is_inf = 157;
    pub const logical_equal = 164;
    pub const logical_not_equal = 165;
    pub const logical_or = 166;
    pub const logical_and = 167;
    pub const logical_not = 168;
    pub const select = 169;
    pub const i_equal = 170;
    pub const i_not_equal = 171;
    pub const u_greater_than = 172;
    pub const s_greater_than = 173;
    pub const u_greater_than_equal = 174;
    pub const s_greater_than_equal = 175;
    pub const u_less_than = 176;
    pub const s_less_than = 177;
    pub const u_less_than_equal = 178;
    pub const s_less_than_equal = 179;
    pub const f_ord_equal = 180;
    pub const f_unord_equal = 181;
    pub const f_ord_not_equal = 182;
    pub const f_unord_not_equal = 183;
    pub const f_ord_less_than = 184;
    pub const f_unord_less_than = 185;
    pub const f_ord_greater_than = 186;
    pub const f_unord_greater_than = 187;
    pub const f_ord_less_than_equal = 188;
    pub const f_unord_less_than_equal = 189;
    pub const f_ord_greater_than_equal = 190;
    pub const f_unord_greater_than_equal = 191;
    pub const shift_right_logical = 194;
    pub const shift_right_arithmetic = 195;
    pub const shift_left_logical = 196;
    pub const bitwise_or = 197;
    pub const bitwise_xor = 198;
    pub const bitwise_and = 199;
    pub const not = 200;
    pub const bit_field_insert = 201;
    pub const bit_field_s_extract = 202;
    pub const bit_field_u_extract = 203;
    pub const bit_reverse = 204;
    pub const bit_count = 205;
    pub const dpdx = 207;
    pub const dpdy = 208;
    pub const fwidth = 209;
    pub const dpdx_fine = 210;
    pub const dpdy_fine = 211;
    pub const fwidth_fine = 212;
    pub const dpdx_coarse = 213;
    pub const dpdy_coarse = 214;
    pub const fwidth_coarse = 215;
    pub const control_barrier = 224;
    pub const memory_barrier = 225;
    pub const atomic_load = 227;
    pub const atomic_store = 228;
    pub const atomic_exchange = 229;
    pub const atomic_compare_exchange = 230;
    pub const atomic_compare_exchange_weak = 231;
    pub const atomic_i_increment = 232;
    pub const atomic_i_decrement = 233;
    pub const atomic_i_add = 234;
    pub const atomic_i_sub = 235;
    pub const atomic_s_min = 236;
    pub const atomic_u_min = 237;
    pub const atomic_s_max = 238;
    pub const atomic_u_max = 239;
    pub const atomic_and = 240;
    pub const atomic_or = 241;
    pub const atomic_xor = 242;
    pub const phi = 245;
    pub const loop_merge = 246;
    pub const selection_merge = 247;
    pub const label = 248;
    pub const branch = 249;
    pub const branch_conditional = 250;
    pub const @"switch" = 251;
    pub const kill = 252;
    pub const @"return" = 253;
    pub const return_value = 254;
    pub const @"unreachable" = 255;
    pub const no_line = 317;
    pub const module_processed = 330;
    pub const execution_mode_id = 331;
    pub const decorate_id = 332;
    // OpGroupNonUniform*: 333 (Elect) .. 366 (QuadSwap)
    pub const group_non_uniform_elect = 333;
    pub const group_non_uniform_all = 334;
    pub const group_non_uniform_any = 335;
    pub const group_non_uniform_all_equal = 336;
    pub const group_non_uniform_broadcast = 337;
    pub const group_non_uniform_broadcast_first = 338;
    pub const group_non_uniform_ballot = 339;
    pub const group_non_uniform_inverse_ballot = 340;
    pub const group_non_uniform_ballot_bit_extract = 341;
    pub const group_non_uniform_ballot_bit_count = 342;
    pub const group_non_uniform_ballot_find_lsb = 343;
    pub const group_non_uniform_ballot_find_msb = 344;
    pub const group_non_uniform_shuffle = 345;
    pub const group_non_uniform_shuffle_xor = 346;
    pub const group_non_uniform_shuffle_up = 347;
    pub const group_non_uniform_shuffle_down = 348;
    pub const group_non_uniform_i_add = 349;
    pub const group_non_uniform_f_add = 350;
    pub const group_non_uniform_i_mul = 351;
    pub const group_non_uniform_f_mul = 352;
    pub const group_non_uniform_s_min = 353;
    pub const group_non_uniform_u_min = 354;
    pub const group_non_uniform_f_min = 355;
    pub const group_non_uniform_s_max = 356;
    pub const group_non_uniform_u_max = 357;
    pub const group_non_uniform_f_max = 358;
    pub const group_non_uniform_bitwise_and = 359;
    pub const group_non_uniform_bitwise_or = 360;
    pub const group_non_uniform_bitwise_xor = 361;
    pub const group_non_uniform_logical_and = 362;
    pub const group_non_uniform_logical_or = 363;
    pub const group_non_uniform_logical_xor = 364;
    pub const group_non_uniform_quad_broadcast = 365;
    pub const group_non_uniform_quad_swap = 366;
    pub const copy_logical = 400;
    pub const terminate_invocation = 4416;
    pub const demote_to_helper_invocation = 5380;
    pub const decorate_string = 5632;
    pub const member_decorate_string = 5633;
};

const StorageClass = struct {
    const uniform_constant = 0;
    const input = 1;
    const uniform = 2;
    const output = 3;
    const workgroup = 4;
    const private = 6;
    const function = 7;
    const push_constant = 9;
    const storage_buffer = 12;
};

const Deco = struct {
    const spec_id = 1;
    const block = 2;
    const buffer_block = 3;
    const row_major = 4;
    const array_stride = 6;
    const matrix_stride = 7;
    const flat = 14;
    const builtin = 11;
    const location = 30;
    const component = 31;
    const binding = 33;
    const descriptor_set = 34;
    const offset = 35;
};

const BuiltIn = struct {
    const position = 0;
    const point_size = 1;
    const clip_distance = 3;
    const cull_distance = 4;
    const frag_coord = 15;
    const front_facing = 17;
    const sample_id = 18;
    const sample_mask = 20;
    const frag_depth = 22;
    const helper_invocation = 23;
    const vertex_index = 42;
    const instance_index = 43;
    const num_workgroups = 24;
    const workgroup_size = 25;
    const workgroup_id = 26;
    const local_invocation_id = 27;
    const global_invocation_id = 28;
    const local_invocation_index = 29;
    const subgroup_size = 36;
    const num_subgroups = 38;
    const subgroup_id = 40;
    const subgroup_local_invocation_id = 41;
    const subgroup_eq_mask = 4416;
    const subgroup_ge_mask = 4417;
    const subgroup_gt_mask = 4418;
    const subgroup_le_mask = 4419;
    const subgroup_lt_mask = 4420;
};

const GLSL = struct {
    const round = 1;
    const round_even = 2;
    const trunc = 3;
    const fabs = 4;
    const sabs = 5;
    const fsign = 6;
    const ssign = 7;
    const floor = 8;
    const ceil = 9;
    const fract = 10;
    const radians = 11;
    const degrees = 12;
    const sin = 13;
    const cos = 14;
    const tan = 15;
    const asin = 16;
    const acos = 17;
    const atan = 18;
    const sinh = 19;
    const cosh = 20;
    const tanh = 21;
    const atan2 = 25;
    const pow = 26;
    const exp = 27;
    const log = 28;
    const exp2 = 29;
    const log2 = 30;
    const sqrt = 31;
    const inverse_sqrt = 32;
    const fmin = 37;
    const umin = 38;
    const smin = 39;
    const fmax = 40;
    const umax = 41;
    const smax = 42;
    const fclamp = 43;
    const uclamp = 44;
    const sclamp = 45;
    const fmix = 46;
    const step = 48;
    const smooth_step = 49;
    const fma = 50;
    const ldexp = 53;
    const pack_snorm4x8 = 54;
    const pack_unorm4x8 = 55;
    const pack_snorm2x16 = 56;
    const pack_unorm2x16 = 57;
    const pack_half2x16 = 58;
    const unpack_snorm2x16 = 60;
    const unpack_unorm2x16 = 61;
    const unpack_half2x16 = 62;
    const unpack_snorm4x8 = 63;
    const unpack_unorm4x8 = 64;
    const length = 66;
    const distance = 67;
    const cross = 68;
    const normalize = 69;
    const face_forward = 70;
    const reflect = 71;
    const find_ilsb = 73;
    const find_smsb = 74;
    const find_umsb = 75;
    const nmin = 79;
    const nmax = 80;
    const nclamp = 81;
};

// ── What the caller gives and gets ─────────────────────────────────────────

/// A specialization constant's value: `size` bytes at `offset` of the data.
pub const SpecEntry = struct { id: u32, offset: u32, size: u32 };

pub const Options = struct {
    /// robustBufferAccess: loads past a binding's range read 0, stores past it are dropped
    robust: bool = true,
    /// the entry point's stage (compute: Gen.compile; vertex, fragment: Gen.emitStage)
    stage: Stage = .compute,
    spec: []const SpecEntry = &.{},
    spec_data: []const u8 = &.{},
    /// The device's subgroup width (Caps.subgroup): the subgroup ops take
    /// 32 or fewer.
    subgroup: u32 = 32,
    /// compute: the caller's texture unit, for sampled images (its slots'
    /// bindings Info.tex_first.., their descriptor words in binding
    /// Info.tex_uni); null: none (a sampled image is unsupported)
    tex: ?*const TexOps = null,
};

pub const BindKind = enum(u8) { storage, uniform, storage_image };
pub const Binding = struct { set: u32, binding: u32, kind: BindKind };

/// What the kernel needs from its dispatch (see the header).
pub const Info = struct {
    group: [3]u32 = .{ 1, 1, 1 },
    bindings: [MAX_BINDINGS]Binding = undefined,
    n_bindings: u8 = 0,
    /// The push-constant block's bytes (0: none).
    push_bytes: u32 = 0,
    /// The storage images among the bindings (bit b: binding b is one).
    image_bits: u32 = 0,
    n_images: u8 = 0,
    /// sampled images (compute, Options.tex): the texture slots used, the
    /// KIR binding of their descriptor words, the first of their images'
    /// (tex_room of them, after the buffers)
    n_tex: u8 = 0,
    tex: [MAX_TEX]TexSlot = undefined,
    tex_uni: u8 = 0,
    tex_first: u8 = 0,
    tex_room: u8 = 0,

    /// The parameter words a dispatch fills: two per binding, the push
    /// constants, then four per storage image.
    pub fn paramWords(info: *const Info) u32 {
        return 2 * @as(u32, info.n_bindings) + (info.push_bytes + 3) / 4 + 4 * @as(u32, info.n_images);
    }

    /// Binding b's storage-image words' first parameter word.
    pub fn imageWord(info: *const Info, b: u32) u32 {
        const below = info.image_bits & ((@as(u32, 1) << @intCast(b)) - 1);
        return 2 * @as(u32, info.n_bindings) + (info.push_bytes + 3) / 4 + 4 * @popCount(below);
    }
};

/// A storage image format (SPIR-V's ImageFormat) as it is in memory:
/// `comps` 32-bit components of `ty`, or four unorm bytes in one word.
/// How a storage image's texel is kept: `comps` 32-bit words of `ty`, or
/// (unorm8) four bytes in one word. The 8- and 16-bit formats WebGPU
/// stores to are kept widened, a word a channel (the driver converts at
/// copies, vk's format.sig): `quant` rounds a write to what the narrow
/// format holds.
pub const StorageFormat = struct { comps: u8, ty: kir.Ty, unorm8: bool = false, quant: Quant = .none };
pub const Quant = enum(u8) { none, snorm8, u8, s8, u16, s16 };

pub fn storageFormat(image_format: u32) ?StorageFormat {
    return switch (image_format) {
        1 => .{ .comps = 4, .ty = .f32 }, // Rgba32f
        2 => .{ .comps = 4, .ty = .f32 }, // Rgba16f (widened)
        7 => .{ .comps = 2, .ty = .f32 }, // Rg16f
        9 => .{ .comps = 1, .ty = .f32 }, // R16f
        5 => .{ .comps = 4, .ty = .f32, .quant = .snorm8 }, // Rgba8Snorm
        22 => .{ .comps = 4, .ty = .i32, .quant = .s16 }, // Rgba16i
        23 => .{ .comps = 4, .ty = .i32, .quant = .s8 }, // Rgba8i
        31 => .{ .comps = 4, .ty = .u32, .quant = .u16 }, // Rgba16ui
        32 => .{ .comps = 4, .ty = .u32, .quant = .u8 }, // Rgba8ui
        3 => .{ .comps = 1, .ty = .f32 }, // R32f
        4 => .{ .comps = 4, .ty = .f32, .unorm8 = true }, // Rgba8
        6 => .{ .comps = 2, .ty = .f32 }, // Rg32f
        21 => .{ .comps = 4, .ty = .i32 }, // Rgba32i
        24 => .{ .comps = 1, .ty = .i32 }, // R32i
        25 => .{ .comps = 2, .ty = .i32 }, // Rg32i
        30 => .{ .comps = 4, .ty = .u32 }, // Rgba32ui
        33 => .{ .comps = 1, .ty = .u32 }, // R32ui
        35 => .{ .comps = 2, .ty = .u32 }, // Rg32ui
        else => null,
    };
}

/// The shader stage an entry point is compiled for.
pub const Stage = enum(u8) { compute, vertex, fragment };

pub const SetBinding = struct { set: u32, binding: u32 };

/// Texture slots a graphics pipeline may have (gfxapi's texture.MAX_TEX).
pub const MAX_TEX = 16;
/// Vertex input locations, and scalar varyings (four a location).
pub const MAX_ATTRS = 16;
pub const MAX_VARYINGS = 64;

/// A texture slot: an image with the sampler it is sampled through, or an
/// image alone (fetched, its size asked).
pub const TexSlot = struct { image: SetBinding, sampler: SetBinding, has_sampler: bool };

/// What a graphics pipeline's stages use, gathered as each compiles once
/// (`frozen` off), then fixed (`frozen` on: a use not listed is an error):
/// buffers and texture slots in the order first used, shared by the stages.
pub const Resources = struct {
    bufs: [MAX_BINDINGS]Binding = undefined,
    n_bufs: u8 = 0,
    tex: [MAX_TEX]TexSlot = undefined,
    n_tex: u8 = 0,
    push_bytes: u32 = 0,
    /// vertex input locations read (bit l), fragment output locations written
    attrs: u32 = 0,
    outputs: u32 = 0,
    /// scalar varyings the vertex stage writes (four a location), those the
    /// fragment stage reads, and the flat ones (bit 4l + c)
    varyings_out: u8 = 0,
    varyings_in: u8 = 0,
    flat: u64 = 0,
    /// the fragment stage takes derivatives: it runs for whole quads
    quads: bool = false,
    frozen: bool = false,
};

pub const Dim = enum(u8) { d1 = 0, d2 = 1, d3 = 2, cube = 3, rect = 4, buffer = 5, subpass = 6 };
pub const SampleKind = enum(u8) { float, int, uint };

/// An image read: its slot and what its type says.
pub const ImageRef = struct {
    slot: u32,
    dim: Dim,
    arrayed: bool,
    depth: bool,
    kind: SampleKind,
    /// a depth comparison's reference (OpImageSampleDref*)
    compare: ?Arg = null,
    /// compute: the KIR bindings of the slot's image and of the
    /// descriptor words (Info.tex_first + slot, Info.tex_uni); 0xff in a
    /// graphics stage (the caller's own)
    bind: u8 = 0xff,
    uni: u8 = 0xff,
};

/// A sample's level of detail: none (the base level), given, or from the
/// coordinates' derivatives across (dx) and up (dy), plus a bias.
pub const Lod = union(enum) {
    base,
    level: Arg,
    grad: struct { dx: [3]Arg, dy: [3]Arg, bias: Arg },
};

/// The caller's texture unit (src/vk: gfxapi's texture.sig).
pub const TexOps = struct {
    ctx: ?*const anyopaque = null,
    /// coords: s, t, r (a cube's direction is three), then an array's
    /// layer; offset in texels
    sample: *const fn (?*const anyopaque, *kir.Kernel, ImageRef, [4]Arg, Lod, [3]i32) [4]Arg,
    /// integer coords (x, y, then z or the layer), the level
    fetch: *const fn (?*const anyopaque, *kir.Kernel, ImageRef, [4]Arg, Arg) [4]Arg,
    /// level `lod`'s width, height, and depth or layers
    size: *const fn (?*const anyopaque, *kir.Kernel, ImageRef, Arg) [3]Arg,
    levels: *const fn (?*const anyopaque, *kir.Kernel, ImageRef) Arg,
};

/// Where a graphics stage's code meets the raster's kernel (see the header).
pub const StageIO = struct {
    /// the binding of the draw's words, and the words: the framebuffer's
    /// height (f32), the base vertex and instance, the push constants, the
    /// buffers' views (offset, range each)
    uni: u8 = 0,
    word_height: u32 = 0,
    word_base_vertex: u32 = 0,
    word_base_instance: u32 = 0,
    word_push: u32 = 0,
    word_views: u32 = 0,
    /// the first buffer's KIR binding
    buffers: u8 = 0,
    tex: ?*const TexOps = null,
    // vertex: in
    attr: ?*const [MAX_ATTRS][4]V = null,
    vertex_id: V = .none,
    instance_id: V = .none,
    // vertex: out (f32 registers)
    position: [4]V = .{ .none, .none, .none, .none },
    varying_out: [MAX_VARYINGS]V = [_]V{.none} ** MAX_VARYINGS,
    // fragment: in
    varying_in: ?*const [MAX_VARYINGS]V = null,
    /// x + 0.5, y + 0.5 from the bottom, depth, 1/w
    frag_coord: [4]V = .{ .none, .none, .none, .none },
    front_facing: V = .none,
    /// whole quads run (derivatives by shuffles with lane ^ quad_x, quad_y)
    quads: bool = false,
    odd_x: V = .none,
    odd_y: V = .none,
    quad_x: u32 = 1,
    quad_y: u32 = 8,
    // fragment: out
    /// the output location that is the colour (the rest are dropped)
    color_loc: u32 = 0,
    /// fragment: the colour location's attachment is sRGB: its colour is
    /// encoded here (linear to sRGB), the raster writing bytes as unorm
    srgb: bool = false,
    color: [4]V = .{ .none, .none, .none, .none },
    discard: V = .none,
};

const Def = struct {
    op: u16 = 0,
    /// the defining instruction's first word (a block: its OpLabel)
    at: u32 = 0,
    binding: u32 = NONE,
    set: u32 = NONE,
    builtin: u32 = NONE,
    spec: u32 = NONE,
    stride: u32 = 0,
    block: bool = false,
    /// a struct: its first member slot
    mstart: u32 = 0,
    /// a block: its merge instruction (0: none) and terminator; a function: its OpFunctionEnd
    merge_at: u32 = 0,
    term_at: u32 = 0,
    /// a buffer variable: its KIR binding (NONE: unused)
    kbind: u32 = NONE,
    location: u32 = NONE,
    component: u32 = 0,
    flat: bool = false,
};

const Member = struct { offset: u32 = NONE, mstride: u32 = 0, builtin: u32 = NONE };

const Comps = struct { start: u32 = 0, n: u32 = 0 };

const Space = enum(u8) { buffer, shared, func, push, input, handle };

/// A pointer: where a value lives.
const Ptr = struct {
    space: Space,
    /// buffer: the KIR binding; func: the variable's first register; input: the variable's id
    slot: u32,
    /// the pointee's type
    ty: u32,
    /// the dynamic part of the offset (bytes; func: components); u(0) when none
    off: Arg = .{ .imm = 0 },
    /// the static part
    imm: u32 = 0,
    /// buffer and push: the matrix stride a matrix inside takes
    mstride: u32 = 16,
    /// func, dynamically indexed: the components the offset ranges over
    lo: u32 = 0,
    hi: u32 = 0,
};

const Val = union(enum) { none, comps: Comps, ptr: Ptr };

const Input = struct { id: u32, comps: Comps };

/// Caller-owned storage for one compile (large: keep it static).
pub const Scratch = struct {
    defs: [MAX_IDS]Def = undefined,
    vals: [MAX_IDS]Val = undefined,
    members: [MAX_MEMBERS]Member = undefined,
    args: [MAX_ARGS]Arg = undefined,
    lay_off: [MAX_LAYOUT]u32 = undefined,
    lay_ty: [MAX_LAYOUT]kir.Ty = undefined,
};

// ── The front end ───────────────────────────────────────────────────────────

const LoopFrame = struct { header: u32, merge: u32, cont: u32 };
const SwitchFrame = struct { merge: u32, cont_flag: V };
const FuncFrame = struct {
    entry: bool,
    wrapped: bool,
    flag: V,
    ret: Comps,
};
const Frame = union(enum) { loop: LoopFrame, sw: SwitchFrame, func: FuncFrame };

pub const Gen = struct {
    w: []const u32,
    s: *Scratch,
    k: *kir.Kernel = undefined,
    opts: Options,
    bound: u32 = 0,
    nmembers: u32 = 0,
    nargs: u32 = 0,
    glsl_set: u32 = NONE,
    entry: u32 = NONE,
    info: Info = .{},
    view: [MAX_BINDINGS]Arg = undefined,
    range: [MAX_BINDINGS]Arg = undefined,
    lim: [MAX_BINDINGS]Arg = undefined,
    inputs: [48]Input = undefined,
    n_inputs: u32 = 0,
    push_var: u32 = NONE,
    frames: [MAX_FRAMES]Frame = undefined,
    nf: u32 = 0,
    diag_buf: [160]u8 = undefined,
    diag_len: usize = 0,
    /// the last inlined call's result
    last_ret: Comps = .{},
    // graphics stages (emitStage)
    io: ?*StageIO = null,
    res: ?*Resources = null,
    /// a compute shader's texture slots (g.res there)
    cres: Resources = .{},
    discard: V = .none,
    wrap_entry: bool = false,
    outs: [32]Out = undefined,
    n_outs: u32 = 0,

    const Out = struct { id: u32, first: u32, ty: u32 };

    /// Compiles entry point `entry_name` (GLCompute) into `k` (over
    /// `storage`); `diag` says what went wrong. Returns what its dispatches need.
    pub fn compile(g: *Gen, entry_name: []const u8, storage: kir.Storage, k: *kir.Kernel) Error!Info {
        try g.parse(entry_name);
        try g.build(storage, entry_name, k);
        return g.info;
    }

    pub fn diag(g: *const Gen) []const u8 {
        return g.diag_buf[0..g.diag_len];
    }

    fn say(g: *Gen, comptime fmt: []const u8, a: anytype) void {
        if (g.diag_len != 0) return;
        const out = std.fmt.bufPrint(&g.diag_buf, fmt, a) catch g.diag_buf[0..];
        g.diag_len = out.len;
    }

    fn unsupported(g: *Gen, comptime fmt: []const u8, a: anytype) Error {
        g.say(fmt, a);
        return error.Unsupported;
    }

    fn bad(g: *Gen, comptime fmt: []const u8, a: anytype) Error {
        g.say(fmt, a);
        return error.BadSpirv;
    }

    // ── Words ──

    fn opAt(g: *const Gen, at: u32) u16 {
        return @truncate(g.w[at]);
    }
    fn wcAt(g: *const Gen, at: u32) u32 {
        return g.w[at] >> 16;
    }
    fn inst(g: *const Gen, at: u32) []const u32 {
        return g.w[at .. at + g.wcAt(at)];
    }
    fn def(g: *Gen, id: u32) *Def {
        return &g.s.defs[id];
    }
    fn tyInst(g: *const Gen, t: u32) []const u32 {
        return g.inst(g.s.defs[t].at);
    }
    fn tyOp(g: *const Gen, t: u32) u16 {
        return g.s.defs[t].op;
    }

    // ── Parsing ──

    /// Reads the module, finds `entry_name`'s GLCompute entry point.
    pub fn parse(g: *Gen, entry_name: []const u8) Error!void {
        const w = g.w;
        if (w.len < 5 or w[0] != MAGIC) return g.bad("spirv: not a SPIR-V module", .{});
        g.bound = w[3];
        if (g.bound > MAX_IDS) return g.bad("spirv: {d} ids, more than {d}", .{ g.bound, MAX_IDS });
        @memset(g.s.defs[0..g.bound], .{});
        @memset(g.s.vals[0..g.bound], .none);
        var at: u32 = 5;
        var cur_label: u32 = NONE;
        var cur_func: u32 = NONE;
        while (at < w.len) {
            const wc = g.wcAt(at);
            if (wc == 0 or at + wc > w.len) return g.bad("spirv: bad instruction at word {d}", .{at});
            const in = w[at .. at + wc];
            const op = g.opAt(at);
            switch (op) {
                Op.ext_inst_import => {
                    if (wc < 3) return error.BadSpirv;
                    if (std.mem.eql(u8, litStr(in[2..]), "GLSL.std.450")) g.glsl_set = in[1];
                    try g.record(in[1], op, at);
                },
                Op.entry_point => {
                    if (wc < 4) return error.BadSpirv;
                    const model: u32 = switch (g.opts.stage) {
                        .compute => 5,
                        .vertex => 0,
                        .fragment => 4,
                    };
                    if (in[1] == model and std.mem.eql(u8, litStr(in[3..]), entry_name)) g.entry = in[2];
                },
                Op.type_void, Op.type_bool, Op.type_int, Op.type_float, Op.type_vector, Op.type_matrix, Op.type_array, Op.type_runtime_array, Op.type_pointer, Op.type_function, Op.type_image, Op.type_sampler, Op.type_sampled_image => try g.record(in[1], op, at),
                Op.type_struct => {
                    try g.record(in[1], op, at);
                    const n: u32 = wc - 2;
                    if (g.nmembers + n > MAX_MEMBERS) return error.TooBig;
                    g.s.defs[in[1]].mstart = g.nmembers;
                    @memset(g.s.members[g.nmembers .. g.nmembers + n], .{});
                    g.nmembers += n;
                },
                Op.function => {
                    try g.record(in[2], op, at);
                    cur_func = in[2];
                },
                Op.function_end => {
                    if (cur_func != NONE) g.s.defs[cur_func].term_at = at;
                    cur_func = NONE;
                },
                Op.label => {
                    try g.record(in[1], op, at);
                    cur_label = in[1];
                },
                Op.loop_merge, Op.selection_merge => if (cur_label != NONE) {
                    g.s.defs[cur_label].merge_at = at;
                },
                Op.branch, Op.branch_conditional, Op.@"switch", Op.@"return", Op.return_value, Op.@"unreachable", Op.kill, Op.terminate_invocation => if (cur_label != NONE) {
                    g.s.defs[cur_label].term_at = at;
                    cur_label = NONE;
                },
                Op.decorate, Op.member_decorate, Op.decorate_id, Op.decorate_string, Op.member_decorate_string, Op.decoration_group, Op.name, Op.member_name, Op.string, Op.line, Op.no_line, Op.source, Op.source_continued, Op.source_extension, Op.module_processed, Op.capability, Op.extension, Op.memory_model, Op.execution_mode, Op.execution_mode_id, Op.nop => {},
                else => {
                    // the rest with a result: types first, then (type, id)
                    if (hasResult(op) and wc >= 3) try g.record(in[2], op, at);
                },
            }
            at += wc;
        }
        if (g.entry == NONE) {
            g.say("spirv: no {s} entry point \"{s}\"", .{ switch (g.opts.stage) {
                .compute => "GLCompute",
                .vertex => "Vertex",
                .fragment => "Fragment",
            }, entry_name });
            return error.NoEntryPoint;
        }
        // decorations and execution modes (they come before the types they name)
        at = 5;
        while (at < w.len) {
            const wc = g.wcAt(at);
            const in = w[at .. at + wc];
            switch (g.opAt(at)) {
                Op.decorate => if (wc >= 3 and in[1] < g.bound) {
                    const d = &g.s.defs[in[1]];
                    const v = if (wc >= 4) in[3] else 0;
                    switch (in[2]) {
                        Deco.spec_id => d.spec = v,
                        Deco.block, Deco.buffer_block => d.block = true,
                        Deco.array_stride => d.stride = v,
                        Deco.builtin => d.builtin = v,
                        Deco.binding => d.binding = v,
                        Deco.location => d.location = v,
                        Deco.component => d.component = v,
                        Deco.flat => d.flat = true,
                        Deco.descriptor_set => d.set = v,
                        else => {},
                    }
                },
                Op.member_decorate => if (wc >= 4 and in[1] < g.bound and g.s.defs[in[1]].op == Op.type_struct) {
                    const d = &g.s.defs[in[1]];
                    const n = g.wcAt(d.at) - 2;
                    if (in[2] < n) {
                        const m = &g.s.members[d.mstart + in[2]];
                        const v = if (wc >= 5) in[4] else 0;
                        switch (in[3]) {
                            Deco.offset => m.offset = v,
                            Deco.matrix_stride => m.mstride = v,
                            Deco.builtin => m.builtin = v,
                            Deco.row_major => return g.unsupported("spirv: row-major matrices", .{}),
                            else => {},
                        }
                    }
                },
                Op.execution_mode => if (wc >= 3 and in[1] == g.entry) {
                    if (in[2] == 17 and wc >= 6) g.info.group = .{ in[3], in[4], in[5] };
                },
                Op.execution_mode_id => if (wc >= 6 and in[1] == g.entry and in[2] == 38) {
                    g.info.group = .{ 0, 0, 0 };
                    for (0..3) |a| g.info.group[a] = g.constScalar(in[3 + a]) orelse return g.unsupported("spirv: LocalSizeId of a non-constant", .{});
                },
                else => {},
            }
            at += wc;
        }
        // constants (after the decorations: SpecId)
        at = 5;
        while (at < w.len) {
            const wc = g.wcAt(at);
            const op = g.opAt(at);
            if (op == Op.function) break;
            switch (op) {
                Op.constant, Op.constant_true, Op.constant_false, Op.constant_composite, Op.constant_null, Op.spec_constant, Op.spec_constant_true, Op.spec_constant_false, Op.spec_constant_composite, Op.undef => try g.constant(at),
                Op.spec_constant_op => return g.unsupported("spirv: OpSpecConstantOp", .{}),
                else => {},
            }
            at += wc;
        }
        // a WorkgroupSize built-in constant overrides LocalSize
        for (0..g.bound) |id| {
            const d = g.s.defs[id];
            if (d.builtin == BuiltIn.workgroup_size and (d.op == Op.constant_composite or d.op == Op.spec_constant_composite)) {
                const c = g.args(@intCast(id));
                if (c.len == 3) {
                    for (0..3) |a| {
                        g.info.group[a] = if (c[a] == .imm) c[a].imm else return error.BadSpirv;
                    }
                }
            }
        }
        if (g.info.group[0] == 0 or g.info.group[1] == 0 or g.info.group[2] == 0) return g.bad("spirv: a workgroup of no threads", .{});
    }

    fn record(g: *Gen, id: u32, op: u16, at: u32) Error!void {
        if (id >= g.bound) return g.bad("spirv: id {d} past the bound", .{id});
        g.s.defs[id].op = op;
        g.s.defs[id].at = at;
    }

    // ── Types ──

    fn lenOf(g: *Gen, t: u32) u32 {
        return switch (g.tyOp(t)) {
            Op.type_vector, Op.type_matrix => g.tyInst(t)[3],
            Op.type_array => g.constScalar(g.tyInst(t)[3]) orelse 0,
            Op.type_struct => g.wcAt(g.s.defs[t].at) - 2,
            else => 1,
        };
    }

    /// The element type (vectors, matrices, arrays) or member `m` (structs).
    fn elemOf(g: *Gen, t: u32, m: u32) u32 {
        return switch (g.tyOp(t)) {
            Op.type_vector, Op.type_matrix, Op.type_array, Op.type_runtime_array => g.tyInst(t)[2],
            Op.type_struct => g.tyInst(t)[2 + m],
            Op.type_pointer => g.tyInst(t)[3],
            else => t,
        };
    }

    /// Scalar components of a value of type `t` (flattened).
    fn comps(g: *Gen, t: u32) u32 {
        return switch (g.tyOp(t)) {
            Op.type_bool, Op.type_int, Op.type_float => 1,
            Op.type_vector, Op.type_matrix, Op.type_array => g.lenOf(t) * g.comps(g.elemOf(t, 0)),
            Op.type_struct => blk: {
                var n: u32 = 0;
                for (0..g.lenOf(t)) |m| n += g.comps(g.elemOf(t, @intCast(m)));
                break :blk n;
            },
            else => 0,
        };
    }

    /// The KIR type of a scalar (or of a vector's components).
    fn scalarTy(g: *Gen, t: u32) Error!kir.Ty {
        const in = g.tyInst(t);
        return switch (g.tyOp(t)) {
            Op.type_bool => .pred,
            Op.type_int => if (in[2] != 32) g.unsupported("spirv: {d}-bit integers", .{in[2]}) else if (in[3] != 0) .i32 else .u32,
            // (f16 values live as f32 registers holding the half's value:
            // every result rounded to half precision, 16 bits in memory)
            Op.type_float => if (in[2] != 32 and in[2] != 16) g.unsupported("spirv: {d}-bit floats", .{in[2]}) else .f32,
            Op.type_vector, Op.type_matrix, Op.type_array, Op.type_runtime_array => g.scalarTy(g.elemOf(t, 0)),
            else => g.bad("spirv: no scalar type in type {d}", .{t}),
        };
    }

    /// Whether type `t` is f16, or a vector or matrix of it.
    fn isHalf(g: *const Gen, t: u32) bool {
        return switch (g.tyOp(t)) {
            Op.type_float => g.tyInst(t)[2] == 16,
            Op.type_vector, Op.type_matrix => g.isHalf(g.tyInst(t)[2]),
            else => false,
        };
    }

    /// x rounded to half precision (to nearest even), as an f32.
    fn roundHalf(g: *Gen, x: Arg) Arg {
        if (x == .imm) {
            const h: f16 = @floatCast(@as(f32, @bitCast(x.imm)));
            return f(@floatCast(h));
        }
        const h = r(g.k.cvt(.f32, .f16, .rne, x));
        return r(g.k.cvt(.f16, .f32, .rne, h));
    }

    /// An f16 result (value `id` of type `t`) rounded to half precision.
    fn roundResult(g: *Gen, t: u32, id: u32) Error!void {
        if (!g.isHalf(t)) return;
        const vals = try g.get(id);
        const c = try g.newComps(@intCast(vals.len));
        for (g.slice(c), vals) |*o, x| o.* = g.roundHalf(x);
        g.setVal(id, c);
    }

    /// Every component's KIR type, in order, into out; returns the count.
    fn compTys(g: *Gen, t: u32, out: []kir.Ty) Error!u32 {
        switch (g.tyOp(t)) {
            Op.type_struct => {
                var n: u32 = 0;
                for (0..g.lenOf(t)) |m| n += try g.compTys(g.elemOf(t, @intCast(m)), out[n..]);
                return n;
            },
            Op.type_array, Op.type_matrix => {
                const e = g.elemOf(t, 0);
                const ec = g.comps(e);
                var n: u32 = 0;
                for (0..g.lenOf(t)) |_| {
                    if (n + ec > out.len) return error.TooBig;
                    _ = try g.compTys(e, out[n..]);
                    n += ec;
                }
                return n;
            },
            else => {
                const n = g.comps(t);
                if (n > out.len) return error.TooBig;
                const st = try g.scalarTy(t);
                for (0..n) |ix| out[ix] = st;
                return n;
            },
        }
    }

    /// The components before member `m` of struct `t`.
    fn memberComps(g: *Gen, t: u32, m: u32) u32 {
        var n: u32 = 0;
        for (0..m) |x| n += g.comps(g.elemOf(t, @intCast(x)));
        return n;
    }

    fn member(g: *Gen, t: u32, m: u32) Member {
        return g.s.members[g.s.defs[t].mstart + m];
    }

    /// Buffer layout: each scalar's byte offset (from `base`) and type, into
    /// the Scratch's layout list from `n`; returns the new count.
    fn layout(g: *Gen, t: u32, base: u32, mstride: u32, n0: u32) Error!u32 {
        var n = n0;
        switch (g.tyOp(t)) {
            Op.type_bool, Op.type_int, Op.type_float => {
                if (n >= MAX_LAYOUT) return error.TooBig;
                g.s.lay_off[n] = base;
                // (.f16: the 16 bits of a half in memory)
                g.s.lay_ty[n] = if (g.isHalf(t)) .f16 else try g.scalarTy(t);
                n += 1;
            },
            Op.type_vector => for (0..g.lenOf(t)) |ix| {
                const eb: u32 = if (g.isHalf(t)) 2 else 4;
                n = try g.layout(g.elemOf(t, 0), base + eb * @as(u32, @intCast(ix)), mstride, n);
            },
            Op.type_matrix => for (0..g.lenOf(t)) |c| {
                n = try g.layout(g.elemOf(t, 0), base + mstride * @as(u32, @intCast(c)), mstride, n);
            },
            Op.type_array => {
                const stride = g.s.defs[t].stride;
                if (stride == 0) return g.bad("spirv: an array in a block without ArrayStride", .{});
                for (0..g.lenOf(t)) |ix| n = try g.layout(g.elemOf(t, 0), base + stride * @as(u32, @intCast(ix)), mstride, n);
            },
            Op.type_struct => for (0..g.lenOf(t)) |mi| {
                const m = g.member(t, @intCast(mi));
                if (m.offset == NONE) return g.bad("spirv: a block member without Offset", .{});
                n = try g.layout(g.elemOf(t, @intCast(mi)), base + m.offset, if (m.mstride != 0) m.mstride else mstride, n);
            },
            else => return g.unsupported("spirv: type op {d} in a buffer", .{g.tyOp(t)}),
        }
        return n;
    }

    // ── Values ──

    fn newComps(g: *Gen, n: u32) Error!Comps {
        if (g.nargs + n > MAX_ARGS) return error.TooBig;
        const c = Comps{ .start = g.nargs, .n = n };
        g.nargs += n;
        return c;
    }
    fn slice(g: *Gen, c: Comps) []Arg {
        return g.s.args[c.start .. c.start + c.n];
    }
    fn args(g: *Gen, id: u32) []Arg {
        return switch (g.s.vals[id]) {
            .comps => |c| g.slice(c),
            else => &.{},
        };
    }
    /// The operands of value `id` (an error when it is none).
    fn get(g: *Gen, id: u32) Error![]Arg {
        if (id >= g.bound) return error.BadSpirv;
        return switch (g.s.vals[id]) {
            .comps => |c| g.slice(c),
            .ptr => g.bad("spirv: pointer %{d} used as a value", .{id}),
            .none => g.bad("spirv: %{d} used before it is defined", .{id}),
        };
    }
    fn ptrOf(g: *Gen, id: u32) Error!Ptr {
        if (id >= g.bound) return error.BadSpirv;
        return switch (g.s.vals[id]) {
            .ptr => |p| p,
            else => g.bad("spirv: %{d} is not a pointer", .{id}),
        };
    }
    fn setVal(g: *Gen, id: u32, c: Comps) void {
        g.s.vals[id] = .{ .comps = c };
    }
    /// Defines `id` as the n operands in `vals`.
    fn define(g: *Gen, id: u32, vals: []const Arg) Error!void {
        const c = try g.newComps(@intCast(vals.len));
        @memcpy(g.slice(c), vals);
        g.setVal(id, c);
    }

    fn constScalar(g: *Gen, id: u32) ?u32 {
        if (id >= g.bound) return null;
        return switch (g.s.vals[id]) {
            .comps => |c| if (c.n == 1 and g.s.args[c.start] == .imm) g.s.args[c.start].imm else null,
            else => null,
        };
    }

    fn specValue(g: *Gen, id: u32) ?u32 {
        const sid = g.s.defs[id].spec;
        if (sid == NONE) return null;
        for (g.opts.spec) |e| {
            if (e.id != sid) continue;
            if (e.offset + e.size > g.opts.spec_data.len or e.size == 0) return null;
            var v: u32 = 0;
            const n = @min(e.size, 4);
            for (0..n) |b| v |= @as(u32, g.opts.spec_data[e.offset + b]) << @intCast(8 * b);
            return v;
        }
        return null;
    }

    fn constant(g: *Gen, at: u32) Error!void {
        const in = g.inst(at);
        if (in.len < 3) return error.BadSpirv;
        const t = in[1];
        const id = in[2];
        switch (g.opAt(at)) {
            Op.constant, Op.spec_constant => {
                if (in.len < 4) return error.BadSpirv;
                if (in.len > 4) return g.unsupported("spirv: 64-bit constants", .{});
                const v = if (g.opAt(at) == Op.spec_constant) (g.specValue(id) orelse in[3]) else in[3];
                if (g.isHalf(t)) {
                    const h: f16 = @bitCast(@as(u16, @truncate(v)));
                    try g.define(id, &.{f(@floatCast(h))});
                } else try g.define(id, &.{u(v)});
            },
            Op.constant_true, Op.constant_false => try g.define(id, &.{u(@intFromBool(g.opAt(at) == Op.constant_true))}),
            Op.spec_constant_true, Op.spec_constant_false => {
                const dflt: u32 = @intFromBool(g.opAt(at) == Op.spec_constant_true);
                const v = g.specValue(id) orelse dflt;
                try g.define(id, &.{u(@intFromBool(v != 0))});
            },
            Op.constant_composite, Op.spec_constant_composite => {
                const n = g.comps(t);
                const c = try g.newComps(n);
                var at_c: u32 = 0;
                for (in[3..]) |part| {
                    const pa = try g.get(part);
                    if (at_c + pa.len > n) return error.BadSpirv;
                    @memcpy(g.slice(c)[at_c..][0..pa.len], pa);
                    at_c += @intCast(pa.len);
                }
                if (at_c != n) return error.BadSpirv;
                g.setVal(id, c);
            },
            Op.constant_null, Op.undef => {
                const n = g.comps(t);
                const c = try g.newComps(n);
                @memset(g.slice(c), u(0));
                g.setVal(id, c);
            },
            else => unreachable,
        }
    }

    // ── Emission helpers ──

    fn reg(g: *Gen, a: Arg, ty: kir.Ty) V {
        return switch (a) {
            .reg => |v| v,
            .imm => g.k.mov(ty, a),
        };
    }

    /// An op with a fresh result; operands all immediates get the first in a register.
    fn op2(g: *Gen, op: kir.Op, ty: kir.Ty, a: Arg, b: Arg) Arg {
        const aa = if (a == .imm and (b == .imm or b == .reg and b.reg == .none)) r(g.reg(a, ty)) else a;
        return r(g.k.op2(op, ty, aa, b));
    }
    fn op1(g: *Gen, op: kir.Op, ty: kir.Ty, a: Arg) Arg {
        const aa = if (a == .imm) r(g.reg(a, ty)) else a;
        return r(g.k.op1(op, ty, aa));
    }
    fn op3(g: *Gen, op: kir.Op, ty: kir.Ty, a: Arg, b: Arg, c: Arg) Arg {
        const aa = if (a == .imm and b == .imm and c == .imm) r(g.reg(a, ty)) else a;
        return r(g.k.op3(op, ty, aa, b, c));
    }

    fn iadd(g: *Gen, a: Arg, b: Arg) Arg {
        if (a == .imm and b == .imm) return u(a.imm +% b.imm);
        if (b == .imm and b.imm == 0) return a;
        if (a == .imm and a.imm == 0) return b;
        return r(g.k.op2(.iadd, .u32, a, b));
    }
    fn isub(g: *Gen, a: Arg, b: Arg) Arg {
        if (a == .imm and b == .imm) return u(a.imm -% b.imm);
        if (b == .imm and b.imm == 0) return a;
        return g.op2(.isub, .u32, a, b);
    }
    fn imul(g: *Gen, a: Arg, b: Arg) Arg {
        if (a == .imm and b == .imm) return u(a.imm *% b.imm);
        if (b == .imm and b.imm == 1) return a;
        if (a == .imm and a.imm == 1) return b;
        if (b == .imm and b.imm == 0) return u(0);
        if (b == .imm and std.math.isPowerOfTwo(b.imm)) return r(g.k.op2(.shl, .u32, a, u(std.math.log2_int(u32, b.imm))));
        return g.op2(.imul, .u32, a, b);
    }
    fn iop(g: *Gen, op: kir.Op, ty: kir.Ty, a: Arg, b: Arg) Arg {
        if (a == .imm and b == .imm) {
            const x = a.imm;
            const y = b.imm;
            const sx: i32 = @bitCast(x);
            const sy: i32 = @bitCast(y);
            const s5: u5 = @truncate(y);
            const v: ?u32 = switch (op) {
                .iadd => x +% y,
                .isub => x -% y,
                .imul => x *% y,
                .@"and" => x & y,
                .@"or" => x | y,
                .xor => x ^ y,
                .shl => x << s5,
                .shr => if (ty == .i32) @bitCast(sx >> s5) else x >> s5,
                .imin => if (ty == .i32) @bitCast(@min(sx, sy)) else @min(x, y),
                .imax => if (ty == .i32) @bitCast(@max(sx, sy)) else @max(x, y),
                else => null,
            };
            if (v) |c| return u(c);
        }
        return g.op2(op, ty, a, b);
    }
    fn sel(g: *Gen, ty: kir.Ty, p: Arg, a: Arg, b: Arg) Arg {
        if (p == .imm) return if (p.imm != 0) a else b;
        if (a == .imm and b == .imm and a.imm == b.imm) return a;
        if (ty == .pred) {
            // (p ? a : b) on preds: (p & a) | (!p & b)
            if (a == .imm and b == .imm) return if (a.imm != 0) p else g.pnot(p);
            return g.por(g.pand(p, a), g.pand(g.pnot(p), b));
        }
        const aa = if (a == .imm and b == .imm) r(g.reg(a, ty)) else a;
        return r(g.k.sel(ty, p, aa, b));
    }
    fn pnot(g: *Gen, p: Arg) Arg {
        if (p == .imm) return u(@intFromBool(p.imm == 0));
        return r(g.k.op1(.pnot, .pred, p));
    }
    fn pand(g: *Gen, a: Arg, b: Arg) Arg {
        if (a == .imm) return if (a.imm != 0) b else u(0);
        if (b == .imm) return if (b.imm != 0) a else u(0);
        return r(g.k.op2(.pand, .pred, a, b));
    }
    fn por(g: *Gen, a: Arg, b: Arg) Arg {
        if (a == .imm) return if (a.imm != 0) u(1) else b;
        if (b == .imm) return if (b.imm != 0) u(1) else a;
        return r(g.k.op2(.por, .pred, a, b));
    }
    fn pxor(g: *Gen, a: Arg, b: Arg) Arg {
        if (a == .imm and b == .imm) return u(@intFromBool((a.imm != 0) != (b.imm != 0)));
        return g.por(g.pand(a, g.pnot(b)), g.pand(g.pnot(a), b));
    }
    fn icmp(g: *Gen, ty: kir.Ty, c: kir.Cmp, a: Arg, b: Arg) Arg {
        if (a == .imm and b == .imm) {
            const x = a.imm;
            const y = b.imm;
            const sx: i32 = @bitCast(x);
            const sy: i32 = @bitCast(y);
            const res = if (ty == .i32) switch (c) {
                .eq => sx == sy,
                .ne => sx != sy,
                .lt => sx < sy,
                .le => sx <= sy,
                .gt => sx > sy,
                .ge => sx >= sy,
            } else switch (c) {
                .eq => x == y,
                .ne => x != y,
                .lt => x < y,
                .le => x <= y,
                .gt => x > y,
                .ge => x >= y,
            };
            return u(@intFromBool(res));
        }
        const aa = if (a == .imm) r(g.reg(a, ty)) else a;
        return r(g.k.cmp(ty, c, aa, b));
    }
    fn fcmp(g: *Gen, c: kir.Cmp, a: Arg, b: Arg) Arg {
        const aa = if (a == .imm and b == .imm) r(g.reg(a, .f32)) else a;
        return r(g.k.cmp(.f32, c, aa, b));
    }
    fn fop(g: *Gen, op: kir.Op, a: Arg, b: Arg) Arg {
        return g.op2(op, .f32, a, b);
    }
    fn fop1(g: *Gen, op: kir.Op, a: Arg) Arg {
        return g.op1(op, .f32, a);
    }
    /// A float value as a register of the given type (a bit cast).
    fn cast(g: *Gen, a: Arg, from: kir.Ty, to: kir.Ty) Arg {
        if (a == .imm) return a;
        const fi = from == .f32 or from == .f16;
        const ti = to == .f32 or to == .f16;
        if (from == to or (!fi and !ti and from != .pred and to != .pred)) return a;
        return r(g.k.mov(to, a));
    }

    /// Unsigned division and remainder (long division; by 0: all ones and a).
    fn udiv(g: *Gen, a: Arg, b: Arg) [2]Arg {
        if (a == .imm and b == .imm) {
            if (b.imm == 0) return .{ u(0xffff_ffff), a };
            return .{ u(a.imm / b.imm), u(a.imm % b.imm) };
        }
        if (b == .imm and b.imm != 0 and std.math.isPowerOfTwo(b.imm)) {
            const sh: u32 = std.math.log2_int(u32, b.imm);
            return .{ g.iop(.shr, .u32, a, u(sh)), g.iop(.@"and", .u32, a, u(b.imm - 1)) };
        }
        const k = g.k;
        var q: Arg = u(0);
        var rem: Arg = u(0);
        var bit: u32 = 32;
        while (bit > 0) {
            bit -= 1;
            const in_bit = r(k.op3(.bfe, .u32, if (a == .imm) r(g.reg(a, .u32)) else a, u(bit), u(1)));
            rem = g.iop(.@"or", .u32, g.iop(.shl, .u32, rem, u(1)), in_bit);
            const ge = g.icmp(.u32, .ge, rem, b);
            rem = g.sel(.u32, ge, g.isub(rem, b), rem);
            q = g.iop(.@"or", .u32, q, g.sel(.u32, ge, u(@as(u32, 1) << @intCast(bit)), u(0)));
        }
        return .{ q, rem };
    }

    /// Signed division and remainder, truncated toward zero.
    fn sdiv(g: *Gen, a: Arg, b: Arg) [2]Arg {
        if (a == .imm and b == .imm) {
            const x: i32 = @bitCast(a.imm);
            const y: i32 = @bitCast(b.imm);
            if (y == 0 or (y == -1 and x == std.math.minInt(i32))) return .{ u(0), a };
            return .{ u(@bitCast(@divTrunc(x, y))), u(@bitCast(@rem(x, y))) };
        }
        const ua = if (a == .imm) u(@abs(@as(i32, @bitCast(a.imm)))) else r(g.k.op1(.iabs, .i32, a));
        const ub = if (b == .imm) u(@abs(@as(i32, @bitCast(b.imm)))) else r(g.k.op1(.iabs, .i32, b));
        const qr = g.udiv(ua, ub);
        const neg_q = g.icmp(.i32, .lt, g.iop(.xor, .i32, a, b), u(0));
        const neg_r = g.icmp(.i32, .lt, a, u(0));
        const q = g.sel(.i32, neg_q, g.op1(.ineg, .i32, qr[0]), qr[0]);
        const rem = g.sel(.i32, neg_r, g.op1(.ineg, .i32, qr[1]), qr[1]);
        return .{ q, rem };
    }

    // ── The kernel ──

    /// Builds the kernel into `k` (its Storage the caller's).
    pub fn build(g: *Gen, storage: kir.Storage, name: []const u8, k: *kir.Kernel) Error!void {
        k.* = kir.Kernel.init(storage, name, g.info.group);
        g.k = k;
        try g.markUses();
        // bindings, in the module's order
        var id: u32 = 0;
        while (id < g.bound) : (id += 1) {
            const d = &g.s.defs[id];
            if (d.op != Op.variable or d.kbind != NONE - 1) continue;
            const sc = g.inst(d.at)[3];
            if (g.info.n_bindings == MAX_BINDINGS) return g.unsupported("spirv: more than {d} buffers", .{MAX_BINDINGS});
            const b = k.binding();
            const kind: BindKind = if (sc == StorageClass.uniform) .uniform else if (sc == StorageClass.uniform_constant) .storage_image else .storage;
            g.info.bindings[b] = .{ .set = if (d.set == NONE) 0 else d.set, .binding = if (d.binding == NONE) 0 else d.binding, .kind = kind };
            g.info.n_bindings += 1;
            if (kind == .storage_image) {
                g.info.image_bits |= @as(u32, 1) << @intCast(b);
                g.info.n_images += 1;
            }
            d.kbind = b;
        }
        // sampled images and samplers (compute): their descriptor words'
        // binding, then a binding for each image variable's slot
        var n_sampled: u32 = 0;
        id = 0;
        while (id < g.bound) : (id += 1) {
            const d = g.s.defs[id];
            if (d.op != Op.variable or d.kbind == NONE or g.inst(d.at)[3] != StorageClass.uniform_constant) continue;
            const t = g.elemOf(g.inst(d.at)[1], 0);
            if (g.tyOp(t) == Op.type_image and !g.isStorageImage(t)) n_sampled += 1;
        }
        if (n_sampled != 0) {
            if (g.opts.tex == null) return g.unsupported("spirv: sampled images in a compute shader without a texture unit", .{});
            g.info.tex_uni = k.binding();
            g.info.tex_first = k.bindings;
            // (an image may be read with a sampler and without: two slots)
            g.info.tex_room = @intCast(@min(2 * n_sampled, MAX_TEX));
            for (0..g.info.tex_room) |_| _ = k.binding();
            g.res = &g.cres;
            g.cres = .{};
        }
        // the prologue: binding views, built-ins, Private and Workgroup variables
        for (0..g.info.n_bindings) |b| {
            g.view[b] = r(k.param(.u32, @intCast(2 * b)));
            g.range[b] = r(k.param(.u32, @intCast(2 * b + 1)));
            g.lim[b] = if (g.opts.robust) r(k.op2(.isub, .u32, r(k.op2(.imax, .u32, g.range[b], u(4))), u(3))) else u(0);
        }
        id = 0;
        while (id < g.bound) : (id += 1) {
            const d = g.s.defs[id];
            if (d.op != Op.variable) continue;
            const in = g.inst(d.at);
            const pty = in[1];
            const sc = in[3];
            const t = g.elemOf(pty, 0);
            switch (sc) {
                StorageClass.storage_buffer, StorageClass.uniform => {
                    if (d.kbind == NONE) continue;
                    if (g.tyOp(t) == Op.type_image or g.tyOp(t) == Op.type_sampler) return g.unsupported("spirv: images", .{});
                    g.s.vals[id] = .{ .ptr = .{ .space = .buffer, .slot = d.kbind, .ty = t } };
                },
                StorageClass.push_constant => {
                    g.push_var = id;
                    g.info.push_bytes = try g.blockBytes(t);
                    g.s.vals[id] = .{ .ptr = .{ .space = .push, .slot = 0, .ty = t } };
                },
                StorageClass.input => {
                    if (d.kbind == NONE) continue;
                    try g.builtinVar(@intCast(id), t);
                },
                StorageClass.workgroup => {
                    if (d.kbind == NONE) continue;
                    const n = g.comps(t);
                    const off = k.sharedAlloc(4 * n, 4);
                    g.s.vals[id] = .{ .ptr = .{ .space = .shared, .slot = 0, .ty = t, .imm = off } };
                },
                StorageClass.private => {
                    if (d.kbind == NONE) continue;
                    try g.funcVar(@intCast(id), t, if (in.len > 4) in[4] else NONE);
                },
                StorageClass.uniform_constant => {
                    if (d.kbind == NONE) continue;
                    g.s.vals[id] = .{ .ptr = .{ .space = .handle, .slot = id, .ty = t } };
                },
                StorageClass.output => {
                    if (d.kbind == NONE) continue;
                    return g.unsupported("spirv: storage class {d} in a compute shader", .{sc});
                },
                StorageClass.function => {},
                else => if (d.kbind != NONE) return g.unsupported("spirv: storage class {d}", .{sc}),
            }
        }
        try g.call(g.entry, &.{}, true);
        if (n_sampled != 0) {
            if (g.cres.n_tex > g.info.tex_room) return g.unsupported("spirv: {d} image and sampler pairs, {d} images", .{ g.cres.n_tex, g.info.tex_room });
            g.info.n_tex = g.cres.n_tex;
            @memcpy(g.info.tex[0..g.cres.n_tex], g.cres.tex[0..g.cres.n_tex]);
        }
        k.finish() catch |e| {
            g.say("spirv: the KIR does not verify ({s})", .{@errorName(e)});
            return e;
        };
    }

    /// The bytes a push-constant block covers.
    fn blockBytes(g: *Gen, t: u32) Error!u32 {
        const n = try g.layout(t, 0, 16, 0);
        var end: u32 = 0;
        for (g.s.lay_off[0..n]) |o| end = @max(end, o + 4);
        return end;
    }

    /// Marks what the entry point and the functions it calls use: buffer,
    /// input, Private and Workgroup variables (kbind NONE - 1: a buffer to bind).
    fn markUses(g: *Gen) Error!void {
        var stack: [64]u32 = undefined;
        var n: usize = 1;
        stack[0] = g.entry;
        var seen_fn: [256]u32 = undefined;
        var n_seen: usize = 0;
        while (n > 0) {
            n -= 1;
            const fid = stack[n];
            if (std.mem.indexOfScalar(u32, seen_fn[0..n_seen], fid) != null) continue;
            if (n_seen == seen_fn.len) return error.TooBig;
            seen_fn[n_seen] = fid;
            n_seen += 1;
            const fd = g.s.defs[fid];
            if (fd.op != Op.function) return g.bad("spirv: %{d} is not a function", .{fid});
            var at = fd.at;
            while (at < fd.term_at) {
                const wc = g.wcAt(at);
                const op = g.opAt(at);
                const in = g.w[at .. at + wc];
                if (op == Op.function_call) {
                    if (n == stack.len) return error.TooBig;
                    stack[n] = in[3];
                    n += 1;
                }
                // ids among the operands (literals may match too: harmless)
                for (in[1..]) |x| {
                    if (x >= g.bound) continue;
                    const d = &g.s.defs[x];
                    if (d.op != Op.variable or d.kbind != NONE) continue;
                    const sc = g.inst(d.at)[3];
                    d.kbind = switch (sc) {
                        StorageClass.storage_buffer, StorageClass.uniform => NONE - 1,
                        StorageClass.function => NONE,
                        StorageClass.uniform_constant => if (g.opts.stage == .compute and g.isStorageImage(g.elemOf(g.inst(d.at)[1], 0))) NONE - 1 else 0,
                        else => 0,
                    };
                }
                at += wc;
            }
        }
    }

    fn builtinVar(g: *Gen, id: u32, t: u32) Error!void {
        const k = g.k;
        const bi = g.s.defs[id].builtin;
        if (bi == NONE) return g.unsupported("spirv: an Input variable that is not a built-in", .{});
        var v: [4]Arg = .{ u(0), u(0), u(0), u(0) };
        var n: u32 = 3;
        switch (bi) {
            BuiltIn.local_invocation_id => for (0..3) |a| {
                v[a] = r(k.tid(@intCast(a)));
            },
            BuiltIn.workgroup_id => for (0..3) |a| {
                v[a] = r(k.gid(@intCast(a)));
            },
            BuiltIn.num_workgroups => for (0..3) |a| {
                v[a] = r(k.gsize(@intCast(a)));
            },
            BuiltIn.global_invocation_id => for (0..3) |a| {
                v[a] = r(k.op3(.imad, .u32, r(k.gid(@intCast(a))), u(g.info.group[a]), r(k.tid(@intCast(a)))));
            },
            BuiltIn.workgroup_size => v = .{ u(g.info.group[0]), u(g.info.group[1]), u(g.info.group[2]), u(0) },
            BuiltIn.local_invocation_index => {
                n = 1;
                v[0] = g.localIndex();
            },
            BuiltIn.subgroup_size => {
                n = 1;
                v[0] = r(k.subgroupWidth());
            },
            BuiltIn.subgroup_local_invocation_id => {
                n = 1;
                v[0] = r(k.lane());
            },
            BuiltIn.subgroup_id => {
                n = 1;
                v[0] = g.udiv(g.localIndex(), r(k.subgroupWidth()))[0];
            },
            BuiltIn.num_subgroups => {
                n = 1;
                const threads = g.info.group[0] * g.info.group[1] * g.info.group[2];
                const w = r(k.subgroupWidth());
                v[0] = g.udiv(g.iadd(u(threads), g.isub(w, u(1))), w)[0];
            },
            BuiltIn.subgroup_eq_mask, BuiltIn.subgroup_ge_mask, BuiltIn.subgroup_gt_mask, BuiltIn.subgroup_le_mask, BuiltIn.subgroup_lt_mask => {
                // (a subgroup of 32 or fewer: the first word only)
                n = 4;
                const ln = r(k.lane());
                const below = g.sel(.u32, g.icmp(.u32, .eq, ln, u(0)), u(0), g.iop(.shr, .u32, u(0xffff_ffff), g.iop(.isub, .u32, u(32), ln)));
                const eq = g.iop(.shl, .u32, u(1), ln);
                v[0] = switch (bi) {
                    BuiltIn.subgroup_eq_mask => eq,
                    BuiltIn.subgroup_lt_mask => below,
                    BuiltIn.subgroup_le_mask => g.iop(.@"or", .u32, below, eq),
                    BuiltIn.subgroup_gt_mask => g.iop(.xor, .u32, g.iop(.@"or", .u32, below, eq), u(0xffff_ffff)),
                    else => g.iop(.xor, .u32, below, u(0xffff_ffff)),
                };
                v[1] = u(0);
                v[2] = u(0);
                v[3] = u(0);
            },
            else => return g.unsupported("spirv: built-in {d}", .{bi}),
        }
        if (g.comps(t) != n) return g.bad("spirv: built-in {d} of the wrong type", .{bi});
        if (g.n_inputs == g.inputs.len) return error.TooBig;
        const c = try g.newComps(n);
        @memcpy(g.slice(c), v[0..n]);
        g.inputs[g.n_inputs] = .{ .id = id, .comps = c };
        g.n_inputs += 1;
        g.s.vals[id] = .{ .ptr = .{ .space = .input, .slot = id, .ty = t } };
    }

    fn localIndex(g: *Gen) Arg {
        const k = g.k;
        const gx = g.info.group[0];
        const gy = g.info.group[1];
        var li = r(k.tid(0));
        if (gy > 1) li = r(k.op3(.imad, .u32, r(k.tid(1)), u(gx), li));
        if (g.info.group[2] > 1) li = r(k.op3(.imad, .u32, r(k.tid(2)), u(gx * gy), li));
        return li;
    }

    /// Registers for a Function or Private variable, set to its initializer or 0.
    fn funcVar(g: *Gen, id: u32, t: u32, init_id: u32) Error!void {
        var tys: [MAX_DYNAMIC]kir.Ty = undefined;
        const n = try g.compTys(t, &tys);
        if (n == 0) return g.unsupported("spirv: a variable of type op {d}", .{g.tyOp(t)});
        const first = g.k.reg(tys[0]);
        for (1..n) |ix| _ = g.k.reg(tys[ix]);
        const initial: ?[]Arg = if (init_id != NONE) try g.get(init_id) else null;
        for (0..n) |ix| {
            const dst: V = @enumFromInt(@intFromEnum(first) + ix);
            g.k.set(dst, .mov, if (initial) |iv| iv[ix] else u(0), no, no);
        }
        g.s.vals[id] = .{ .ptr = .{ .space = .func, .slot = @intFromEnum(first), .ty = t } };
    }

    // ── Functions ──

    /// Inlines function `fid` with `params` as its parameters' values; the
    /// result is the frame's ret.
    fn call(g: *Gen, fid: u32, params: []const Val, entry: bool) Error!void {
        const fd = g.s.defs[fid];
        if (fd.op != Op.function) return error.BadSpirv;
        const fin = g.inst(fd.at);
        const rty = fin[1];
        // parameters, phis, returns and loops
        var np: usize = 0;
        var first_label: u32 = NONE;
        var returns: u32 = 0;
        var loops = false;
        var scan = fd.at + g.wcAt(fd.at);
        while (scan < fd.term_at) {
            const op = g.opAt(scan);
            const in = g.inst(scan);
            switch (op) {
                Op.function_parameter => {
                    if (np >= params.len) return g.bad("spirv: a call with too few arguments", .{});
                    g.s.vals[in[2]] = params[np];
                    np += 1;
                },
                Op.label => if (first_label == NONE) {
                    first_label = in[1];
                },
                Op.phi => {
                    var tys: [MAX_DYNAMIC]kir.Ty = undefined;
                    const n = try g.compTys(in[1], &tys);
                    const c = try g.newComps(n);
                    for (g.slice(c), 0..) |*a, ix| a.* = r(g.k.reg(tys[ix]));
                    g.setVal(in[2], c);
                },
                Op.@"return", Op.return_value => returns += 1,
                Op.loop_merge, Op.@"switch" => loops = true,
                else => {},
            }
            scan += g.wcAt(scan);
        }
        if (first_label == NONE) return g.bad("spirv: a function without blocks", .{});
        // (a graphics stage's entry is inlined into the raster's kernel: its
        // returns and discards leave its own loop, never the kernel)
        const own_loop = g.wrap_entry and fid == g.entry;
        var fr = FuncFrame{ .entry = entry, .wrapped = (!entry and (returns > 1 or loops)) or own_loop, .flag = .none, .ret = .{} };
        if (!entry and g.tyOp(rty) != Op.type_void) {
            if (fr.wrapped) {
                var tys: [MAX_DYNAMIC]kir.Ty = undefined;
                const n = try g.compTys(rty, &tys);
                fr.ret = try g.newComps(n);
                for (g.slice(fr.ret), 0..) |*a, ix| a.* = r(g.k.reg(tys[ix]));
            }
        }
        if (fr.wrapped) {
            fr.flag = g.k.reg(.pred);
            g.k.set(fr.flag, .mov, u(0), no, no);
        }
        try g.push(.{ .func = fr });
        const k = g.k;
        if (fr.wrapped) k.loop();
        try g.region(first_label, NONE);
        if (fr.wrapped) {
            k.brk(u(1));
            k.endloop();
        }
        g.nf -= 1;
        // (the caller reads the result from g.last_ret)
        g.last_ret = g.frames[g.nf].func.ret;
    }

    fn push(g: *Gen, fr: Frame) Error!void {
        if (g.nf == MAX_FRAMES) return g.unsupported("spirv: constructs nested more than {d} deep", .{MAX_FRAMES});
        g.frames[g.nf] = fr;
        g.nf += 1;
    }

    fn funcFrame(g: *Gen) *FuncFrame {
        var i = g.nf;
        while (i > 0) {
            i -= 1;
            if (g.frames[i] == .func) return &g.frames[i].func;
        }
        unreachable;
    }

    // ── Control flow ──

    /// Emits the blocks from `start` until `stop` (or until every path has left).
    fn region(g: *Gen, start: u32, stop: u32) Error!void {
        var cur = start;
        while (cur != stop) {
            if (cur >= g.bound or g.s.defs[cur].op != Op.label) return g.bad("spirv: %{d} is not a block", .{cur});
            const d = g.s.defs[cur];
            if (d.term_at == 0) return g.bad("spirv: block %{d} has no terminator", .{cur});
            if (d.merge_at != 0 and g.opAt(d.merge_at) == Op.loop_merge) {
                const lm = g.inst(d.merge_at);
                try g.loopConstruct(cur, lm[1], lm[2]);
                cur = lm[1];
                continue;
            }
            try g.body(cur);
            const t = g.inst(d.term_at);
            switch (g.opAt(d.term_at)) {
                Op.branch => cur = (try g.edge(cur, t[1])) orelse return,
                Op.branch_conditional => {
                    const c = (try g.get(t[1]))[0];
                    if (d.merge_at != 0 and g.opAt(d.merge_at) == Op.selection_merge) {
                        const m = g.inst(d.merge_at)[1];
                        try g.ifElse(cur, c, t[2], t[3], m);
                        cur = m;
                    } else {
                        cur = (try g.condBranch(cur, c, t[2], t[3])) orelse return;
                    }
                },
                Op.@"switch" => {
                    if (d.merge_at == 0) return g.bad("spirv: a switch without OpSelectionMerge", .{});
                    const m = g.inst(d.merge_at)[1];
                    try g.switchConstruct(cur, t, m);
                    cur = m;
                },
                Op.@"return", Op.return_value => {
                    try g.doReturn(if (g.opAt(d.term_at) == Op.return_value) t[1] else NONE);
                    return;
                },
                Op.kill, Op.terminate_invocation => {
                    if (g.io != null) {
                        g.k.set(g.discard, .mov, u(1), no, no);
                        try g.doReturn(NONE);
                    } else g.k.ret();
                    return;
                },
                Op.@"unreachable" => return,
                else => unreachable,
            }
        }
    }

    fn ifElse(g: *Gen, from: u32, c: Arg, t_lbl: u32, f_lbl: u32, m: u32) Error!void {
        const k = g.k;
        if (c == .imm) {
            const next = (try g.edge(from, if (c.imm != 0) t_lbl else f_lbl)) orelse return;
            return g.region(next, m);
        }
        k.ifp(c);
        if (try g.edge(from, t_lbl)) |next| try g.region(next, m);
        if (f_lbl != m or g.hasPhis(m)) {
            k.els();
            if (try g.edge(from, f_lbl)) |next| try g.region(next, m);
        }
        k.endif();
    }

    /// A conditional branch with no selection merge: one side (or both)
    /// leaves the construct. Returns the block to go on with, if any.
    fn condBranch(g: *Gen, from: u32, c: Arg, t_lbl: u32, f_lbl: u32) Error!?u32 {
        const k = g.k;
        const te = g.isExit(t_lbl);
        const fe = g.isExit(f_lbl);
        if (!te and !fe) return g.unsupported("spirv: an unstructured conditional branch in block %{d}", .{from});
        if (c == .imm) return g.edge(from, if (c.imm != 0) t_lbl else f_lbl);
        if (te and fe) {
            k.ifp(c);
            _ = try g.edge(from, t_lbl);
            k.els();
            _ = try g.edge(from, f_lbl);
            k.endif();
            return null;
        }
        const exit = if (te) t_lbl else f_lbl;
        const stay = if (te) f_lbl else t_lbl;
        const p = if (te) c else g.pnot(c);
        if (g.nf > 0 and g.frames[g.nf - 1] == .loop and !g.hasPhis(exit)) {
            // a plain break or back edge of the innermost loop: one predicated jump
            const l = g.frames[g.nf - 1].loop;
            if (exit == l.merge or exit == l.header) {
                if (exit == l.merge) k.brk(p) else k.cont(p);
                return try g.edge(from, stay);
            }
        }
        k.ifp(p);
        _ = try g.edge(from, exit);
        k.endif();
        return try g.edge(from, stay);
    }

    /// Whether a branch to `to` leaves the innermost loop or switch.
    fn isExit(g: *Gen, to: u32) bool {
        var i = g.nf;
        while (i > 0) {
            i -= 1;
            switch (g.frames[i]) {
                .func => return false,
                .loop => |l| return to == l.merge or to == l.cont or to == l.header,
                .sw => |s| {
                    if (to == s.merge) return true;
                },
            }
        }
        return false;
    }

    /// The branch from block `from` to `to`: its phis set, then a break,
    /// continue or merge, or the block to walk on to.
    fn edge(g: *Gen, from: u32, to: u32) Error!?u32 {
        const k = g.k;
        var i = g.nf;
        var kir_loops: u32 = 0;
        while (i > 0) {
            i -= 1;
            switch (g.frames[i]) {
                .func => break,
                .loop => |l| {
                    if (to == l.merge or to == l.header or to == l.cont) {
                        if (kir_loops == 1 and to == l.cont and g.frames[i + 1] == .sw and g.frames[i + 1].sw.cont_flag != .none) {
                            // a continue from inside a switch
                            try g.setPhis(from, to);
                            k.set(g.frames[i + 1].sw.cont_flag, .mov, u(1), no, no);
                            k.brk(u(1));
                            return null;
                        }
                        if (kir_loops != 0) return g.unsupported("spirv: a branch out of a loop from inside a switch", .{});
                        try g.setPhis(from, to);
                        if (to == l.merge) {
                            k.brk(u(1));
                        } else if (to == l.header) {
                            k.cont(u(1));
                        } else {
                            try g.continueConstruct(l);
                        }
                        return null;
                    }
                    kir_loops += 1;
                },
                .sw => |s| {
                    if (to == s.merge) {
                        if (kir_loops != 0) return g.unsupported("spirv: a branch out of a switch from an inner loop", .{});
                        try g.setPhis(from, to);
                        k.brk(u(1));
                        return null;
                    }
                    kir_loops += 1;
                },
            }
        }
        try g.setPhis(from, to);
        return to;
    }

    fn continueConstruct(g: *Gen, l: LoopFrame) Error!void {
        if (l.cont == l.header) {
            g.k.cont(u(1));
            return;
        }
        // (the continue construct ends with the back edge: a cont)
        try g.region(l.cont, NONE);
    }

    fn hasPhis(g: *Gen, lbl: u32) bool {
        const at = g.s.defs[lbl].at;
        const next = at + g.wcAt(at);
        return next < g.w.len and g.opAt(next) == Op.phi;
    }

    /// Sets the phis of block `to` for the edge from `from`.
    fn setPhis(g: *Gen, from: u32, to: u32) Error!void {
        if (to >= g.bound or g.s.defs[to].op != Op.label) return g.bad("spirv: a branch to %{d}, not a block", .{to});
        const lat = g.s.defs[to].at;
        var at = lat + g.wcAt(lat);
        var n_phis: u32 = 0;
        var scan = at;
        while (scan < g.w.len and g.opAt(scan) == Op.phi) : (scan += g.wcAt(scan)) n_phis += 1;
        if (n_phis == 0) return;
        // two phases when there are several (they read each other's old values)
        var tmp_start: u32 = g.nargs;
        if (n_phis > 1) {
            scan = at;
            while (scan < g.w.len and g.opAt(scan) == Op.phi) : (scan += g.wcAt(scan)) {
                const src = try g.phiSource(scan, from);
                const dst = g.args(g.inst(scan)[2]);
                const c = try g.newComps(@intCast(dst.len));
                for (g.slice(c), src, dst) |*t, s, d| t.* = if (s == .imm) s else r(g.k.mov(g.k.tys[@intFromEnum(d.reg)], s));
            }
        }
        while (at < g.w.len and g.opAt(at) == Op.phi) : (at += g.wcAt(at)) {
            const dst = g.args(g.inst(at)[2]);
            const src = if (n_phis > 1) blk: {
                const s = g.s.args[tmp_start .. tmp_start + dst.len];
                tmp_start += @intCast(dst.len);
                break :blk s;
            } else try g.phiSource(at, from);
            for (dst, src) |d, s| {
                if (!(s == .reg and s.reg == d.reg)) g.k.set(d.reg, .mov, s, no, no);
            }
        }
    }

    fn phiSource(g: *Gen, at: u32, from: u32) Error![]Arg {
        const in = g.inst(at);
        var j: usize = 3;
        while (j + 1 < in.len) : (j += 2) {
            if (in[j + 1] == from) {
                const v = try g.get(in[j]);
                if (v.len != g.args(in[2]).len) return error.BadSpirv;
                return v;
            }
        }
        return g.bad("spirv: phi %{d} has no value from %{d}", .{ in[2], from });
    }

    fn loopConstruct(g: *Gen, header: u32, merge: u32, cont: u32) Error!void {
        const k = g.k;
        const d = g.s.defs[header];
        k.loop();
        try g.push(.{ .loop = .{ .header = header, .merge = merge, .cont = cont } });
        try g.body(header);
        const t = g.inst(d.term_at);
        switch (g.opAt(d.term_at)) {
            Op.branch => if (try g.edge(header, t[1])) |next| try g.region(next, NONE),
            Op.branch_conditional => {
                const c = (try g.get(t[1]))[0];
                if (try g.condBranch(header, c, t[2], t[3])) |next| try g.region(next, NONE);
            },
            else => return g.bad("spirv: loop header %{d} ends oddly", .{header}),
        }
        g.nf -= 1;
        k.endloop();
        try g.afterInnerLoop();
    }

    /// After an inner loop or switch of a function that returns early: the
    /// lanes that returned leave the next loop out too.
    fn afterInnerLoop(g: *Gen) Error!void {
        const fr = g.funcFrame();
        if (fr.wrapped) g.k.brk(r(fr.flag));
    }

    fn switchConstruct(g: *Gen, from: u32, t: []const u32, merge: u32) Error!void {
        const k = g.k;
        const sel_v = (try g.get(t[1]))[0];
        const dflt = t[2];
        // a continue from a case needs a flag (when a loop is right around)
        var in_loop = false;
        var i = g.nf;
        while (i > 0) {
            i -= 1;
            if (g.frames[i] == .func) break;
            if (g.frames[i] == .loop) {
                in_loop = i == g.nf - 1;
                break;
            }
        }
        var flag: V = .none;
        if (in_loop) {
            flag = k.reg(.pred);
            k.set(flag, .mov, u(0), no, no);
        }
        k.loop();
        try g.push(.{ .sw = .{ .merge = merge, .cont_flag = flag } });
        // the cases, each target once (in order)
        var j: usize = 3;
        while (j + 1 < t.len) : (j += 2) {
            const target = t[j + 1];
            var seen = false;
            var jj: usize = 3;
            while (jj < j) : (jj += 2) {
                if (t[jj + 1] == target) seen = true;
            }
            if (seen or target == dflt) continue;
            var cond: Arg = u(0);
            jj = j;
            while (jj + 1 < t.len) : (jj += 2) {
                if (t[jj + 1] == target) cond = g.por(cond, g.icmp(.u32, .eq, sel_v, u(t[jj])));
            }
            if (cond == .imm and cond.imm == 0) continue;
            k.ifp(cond);
            if (try g.edge(from, target)) |next| try g.region(next, NONE);
            k.endif();
        }
        if (try g.edge(from, dflt)) |next| try g.region(next, NONE);
        k.brk(u(1));
        g.nf -= 1;
        k.endloop();
        try g.afterInnerLoop();
        if (flag != .none) {
            // the lanes that continued
            k.ifp(r(flag));
            var li = g.nf;
            while (li > 0) {
                li -= 1;
                if (g.frames[li] == .loop) {
                    try g.continueConstruct(g.frames[li].loop);
                    break;
                }
            }
            k.endif();
        }
    }

    fn doReturn(g: *Gen, value: u32) Error!void {
        const k = g.k;
        const fr = g.funcFrame();
        if (fr.entry) {
            k.ret();
            return;
        }
        if (value != NONE) {
            const v = try g.get(value);
            if (fr.wrapped) {
                for (g.slice(fr.ret), v) |d, s| k.set(d.reg, .mov, s, no, no);
            } else {
                fr.ret = try g.newComps(@intCast(v.len));
                @memcpy(g.slice(fr.ret), v);
            }
        }
        if (!fr.wrapped) return;
        // inside the function's own loop: leave it; deeper: by the flag
        var i = g.nf;
        var inner = false;
        while (i > 0) {
            i -= 1;
            switch (g.frames[i]) {
                .func => break,
                else => inner = true,
            }
        }
        if (inner) k.set(fr.flag, .mov, u(1), no, no);
        k.brk(u(1));
    }

    // ── Blocks ──

    /// The instructions of block `lbl` between its label (and phis) and its merge or terminator.
    fn body(g: *Gen, lbl: u32) Error!void {
        const d = g.s.defs[lbl];
        var at = d.at + g.wcAt(d.at);
        const end = if (d.merge_at != 0) d.merge_at else d.term_at;
        while (at < end) {
            try g.instruction(at);
            at += g.wcAt(at);
        }
    }

    fn instruction(g: *Gen, at: u32) Error!void {
        const in = g.inst(at);
        const op = g.opAt(at);
        const k = g.k;
        switch (op) {
            Op.phi, Op.line, Op.no_line, Op.nop, Op.name, Op.selection_merge, Op.loop_merge => {},
            Op.variable => {
                if (in[3] != StorageClass.function) return g.bad("spirv: a non-Function variable in a function", .{});
                try g.funcVar(in[2], g.elemOf(in[1], 0), if (in.len > 4) in[4] else NONE);
            },
            Op.undef => {
                const c = try g.newComps(g.comps(in[1]));
                @memset(g.slice(c), u(0));
                g.setVal(in[2], c);
            },
            Op.load => {
                const p = try g.ptrOf(in[3]);
                g.setVal(in[2], try g.loadPtr(p));
            },
            Op.atomic_load => {
                // (in memory: an atomic add of 0, so that a spinning
                // reader sees other groups' writes, not a cached word)
                const p = try g.ptrOf(in[3]);
                if (p.space == .buffer or p.space == .shared) try g.atomic(op, in) else g.setVal(in[2], try g.loadPtr(p));
            },
            Op.store => try g.storePtr(try g.ptrOf(in[1]), try g.get(in[2])),
            Op.atomic_store => try g.storePtr(try g.ptrOf(in[1]), try g.get(in[4])),
            Op.copy_memory => {
                const src = try g.loadPtr(try g.ptrOf(in[2]));
                try g.storePtr(try g.ptrOf(in[1]), g.slice(src));
            },
            Op.access_chain, Op.in_bounds_access_chain => {
                var p = try g.ptrOf(in[3]);
                if (p.space == .handle) return g.unsupported("spirv: arrays of images or samplers", .{});
                for (in[4..]) |ix| p = try g.step(p, ix);
                g.s.vals[in[2]] = .{ .ptr = p };
            },
            Op.ptr_access_chain => return g.unsupported("spirv: OpPtrAccessChain", .{}),
            Op.array_length => {
                const p = try g.ptrOf(in[3]);
                if (p.space != .buffer) return g.bad("spirv: OpArrayLength of a non-buffer", .{});
                const st = p.ty;
                const m = g.member(st, in[4]);
                const arr = g.elemOf(st, in[4]);
                const stride = g.s.defs[arr].stride;
                if (m.offset == NONE or stride == 0) return error.BadSpirv;
                const range = g.range[p.slot];
                // (range - offset) / stride, 0 when the range is shorter
                const room = g.op2(.imax, .i32, g.isub(range, u(m.offset)), u(0));
                try g.define(in[2], &.{g.udiv(room, u(stride))[0]});
            },
            Op.function_call => {
                var params: [32]Val = undefined;
                const np = in.len - 4;
                if (np > params.len) return g.unsupported("spirv: a call with {d} arguments", .{np});
                for (in[4..], 0..) |a, ix| params[ix] = g.s.vals[a];
                g.last_ret = .{};
                try g.call(in[3], params[0..np], false);
                if (g.tyOp(in[1]) != Op.type_void) g.setVal(in[2], g.last_ret);
            },
            Op.control_barrier => k.barrier(),
            Op.sampled_image => {
                const im = try g.get(in[3]);
                const sm = try g.get(in[4]);
                if (im.len != 1 or sm.len != 1) return error.BadSpirv;
                try g.define(in[2], &.{ im[0], sm[0] });
            },
            Op.image => {
                const si = try g.get(in[3]);
                try g.define(in[2], si[0..1]);
            },
            Op.image_sample_implicit_lod, Op.image_sample_explicit_lod, Op.image_sample_dref_implicit_lod, Op.image_sample_dref_explicit_lod, Op.image_fetch, Op.image_query_size_lod, Op.image_query_size, Op.image_query_levels, Op.image_query_samples => try g.imageOp(op, in),
            Op.image_read, Op.image_write => try g.storageImageOp(op, in),
            Op.image_sample_proj_implicit_lod, Op.image_sample_proj_explicit_lod, Op.image_gather, Op.image_dref_gather, Op.image_query_lod => return g.unsupported("spirv: image op {d}", .{op}),
            Op.dpdx, Op.dpdy, Op.fwidth, Op.dpdx_fine, Op.dpdy_fine, Op.fwidth_fine, Op.dpdx_coarse, Op.dpdy_coarse, Op.fwidth_coarse => try g.derivative(op, in),
            Op.demote_to_helper_invocation => {
                if (g.io == null) return g.unsupported("spirv: demote outside a fragment shader", .{});
                k.set(g.discard, .mov, u(1), no, no);
            },
            Op.memory_barrier => {},
            Op.copy_object, Op.copy_logical => try g.define(in[2], try g.get(in[3])),
            Op.composite_construct => {
                const n = g.comps(in[1]);
                const c = try g.newComps(n);
                var o: u32 = 0;
                for (in[3..]) |part| {
                    const pa = try g.get(part);
                    if (o + pa.len > n) return error.BadSpirv;
                    @memcpy(g.slice(c)[o..][0..pa.len], pa);
                    o += @intCast(pa.len);
                }
                if (o != n) return error.BadSpirv;
                g.setVal(in[2], c);
            },
            Op.composite_extract => {
                const src = try g.get(in[3]);
                const at_t = try g.compositeAt(g.typeOfValue(in[3]) orelse return error.BadSpirv, in[4..]);
                if (at_t.off + at_t.n > src.len) return error.BadSpirv;
                try g.define(in[2], src[at_t.off..][0..at_t.n]);
            },
            Op.composite_insert => {
                const obj = try g.get(in[3]);
                const src = try g.get(in[4]);
                const at_t = try g.compositeAt(in[1], in[5..]);
                const c = try g.newComps(@intCast(src.len));
                @memcpy(g.slice(c), src);
                @memcpy(g.slice(c)[at_t.off..][0..at_t.n], obj);
                g.setVal(in[2], c);
            },
            Op.vector_shuffle => {
                const a = try g.get(in[3]);
                const b = try g.get(in[4]);
                const c = try g.newComps(@intCast(in.len - 5));
                for (in[5..], g.slice(c)) |sx, *o| {
                    o.* = if (sx == 0xffff_ffff) u(0) else if (sx < a.len) a[sx] else if (sx - a.len < b.len) b[sx - a.len] else return error.BadSpirv;
                }
                g.setVal(in[2], c);
            },
            Op.vector_extract_dynamic => {
                const v = try g.get(in[3]);
                const ix = (try g.get(in[4]))[0];
                const ty = try g.scalarTy(in[1]);
                if (ix == .imm) {
                    try g.define(in[2], &.{if (ix.imm < v.len) v[ix.imm] else u(0)});
                } else {
                    var res = v[0];
                    for (1..v.len) |j| res = g.sel(ty, g.icmp(.u32, .eq, ix, u(@intCast(j))), v[j], res);
                    try g.define(in[2], &.{res});
                }
            },
            Op.vector_insert_dynamic => {
                const v = try g.get(in[3]);
                const x = (try g.get(in[4]))[0];
                const ix = (try g.get(in[5]))[0];
                const ty = try g.scalarTy(in[1]);
                const c = try g.newComps(@intCast(v.len));
                for (g.slice(c), v, 0..) |*o, e, j| o.* = g.sel(ty, g.icmp(.u32, .eq, ix, u(@intCast(j))), x, e);
                g.setVal(in[2], c);
            },
            Op.select => {
                const cnd = try g.get(in[3]);
                const a = try g.get(in[4]);
                const b = try g.get(in[5]);
                var tys: [MAX_DYNAMIC]kir.Ty = undefined;
                const n = try g.compTys(in[1], &tys);
                if (a.len != n or b.len != n) return error.BadSpirv;
                const c = try g.newComps(n);
                for (g.slice(c), 0..) |*o, j| o.* = g.sel(tys[j], if (cnd.len == 1) cnd[0] else cnd[j], a[j], b[j]);
                g.setVal(in[2], c);
            },
            Op.ext_inst => {
                if (in[3] != g.glsl_set) return g.unsupported("spirv: an extended instruction set other than GLSL.std.450", .{});
                try g.glsl(in);
                try g.roundResult(in[1], in[2]);
            },
            Op.atomic_i_add, Op.atomic_i_sub, Op.atomic_s_min, Op.atomic_u_min, Op.atomic_s_max, Op.atomic_u_max, Op.atomic_exchange, Op.atomic_i_increment, Op.atomic_i_decrement => try g.atomic(op, in),
            Op.bit_field_insert, Op.bit_field_s_extract, Op.bit_field_u_extract => try g.bitfield(in, op),
            Op.atomic_and, Op.atomic_or, Op.atomic_xor, Op.atomic_compare_exchange, Op.atomic_compare_exchange_weak => try g.atomic(op, in),
            Op.group_non_uniform_elect...Op.group_non_uniform_quad_swap => {
                try g.subgroup(op, in);
                try g.roundResult(in[1], in[2]);
            },
            Op.transpose => {
                const m = try g.get(in[3]);
                const cols = g.lenOf(in[1]);
                const rows = g.lenOf(g.elemOf(in[1], 0));
                const c = try g.newComps(cols * rows);
                for (0..cols) |ci| {
                    for (0..rows) |ri| g.slice(c)[ci * rows + ri] = m[ri * cols + ci];
                }
                g.setVal(in[2], c);
            },
            Op.bitcast => if (!try g.halfCast(in)) {
                try g.arith(op, in);
            },
            else => {
                try g.arith(op, in);
                try g.roundResult(in[1], in[2]);
            },
        }
    }

    /// A bitcast between halves and 32-bit values (vec2<f16> and a u32,
    /// i32 or f32; vec4<f16> and vec2 of them): the halves' bits packed,
    /// low first. False when neither side is f16.
    fn halfCast(g: *Gen, in: []const u32) Error!bool {
        const src_t = g.typeOfValue(in[3]) orelse return false;
        const to_half = g.isHalf(in[1]);
        if (!to_half and !g.isHalf(src_t)) return false;
        if (to_half and g.isHalf(src_t)) {
            try g.define(in[2], try g.get(in[3]));
            return true;
        }
        const x = try g.get(in[3]);
        if (to_half) {
            // each 32-bit word into two halves
            const c = try g.newComps(@intCast(2 * x.len));
            for (x, 0..) |w0, j| {
                const w = r(g.reg(w0, .u32));
                g.slice(c)[2 * j] = g.unhalf(g.iop(.@"and", .u32, w, u(0xffff)));
                g.slice(c)[2 * j + 1] = g.unhalf(g.iop(.shr, .u32, w, u(16)));
            }
            g.setVal(in[2], c);
        } else {
            if (x.len % 2 != 0) return g.unsupported("spirv: a bitcast of an odd number of halves", .{});
            const dst = try g.scalarTy(in[1]);
            const c = try g.newComps(@intCast(x.len / 2));
            for (g.slice(c), 0..) |*o, j| {
                const w = g.iop(.@"or", .u32, g.half(x[2 * j]), g.iop(.shl, .u32, g.half(x[2 * j + 1]), u(16)));
                o.* = g.cast(w, .u32, dst);
            }
            g.setVal(in[2], c);
        }
        return true;
    }

    const At = struct { off: u32, n: u32 };

    /// Where the element an index path names lies in a value of type `t`.
    fn compositeAt(g: *Gen, t0: u32, path: []const u32) Error!At {
        var t = t0;
        var off: u32 = 0;
        for (path) |ix| {
            switch (g.tyOp(t)) {
                Op.type_struct => {
                    off += g.memberComps(t, ix);
                    t = g.elemOf(t, ix);
                },
                Op.type_vector, Op.type_matrix, Op.type_array => {
                    t = g.elemOf(t, 0);
                    off += ix * g.comps(t);
                },
                else => return error.BadSpirv,
            }
        }
        return .{ .off = off, .n = g.comps(t) };
    }

    /// The type of value `id` (its defining instruction's result type).
    fn typeOfValue(g: *Gen, id: u32) ?u32 {
        if (id >= g.bound) return null;
        const d = g.s.defs[id];
        if (d.op == 0) return null;
        return g.inst(d.at)[1];
    }

    // ── Memory ──

    fn step(g: *Gen, p0: Ptr, ix_id: u32) Error!Ptr {
        var p = p0;
        const t = p.ty;
        const ixa = (try g.get(ix_id))[0];
        const bytes = p.space == .buffer or p.space == .push;
        switch (g.tyOp(t)) {
            Op.type_struct => {
                if (ixa != .imm) return error.BadSpirv;
                const m = ixa.imm;
                if (bytes) {
                    const mem = g.member(t, m);
                    if (mem.offset == NONE) return g.bad("spirv: a block member without Offset", .{});
                    p.imm += mem.offset;
                    if (mem.mstride != 0) p.mstride = mem.mstride;
                } else {
                    p.imm += g.unit(p.space) * g.memberComps(t, m);
                }
                p.ty = g.elemOf(t, m);
            },
            Op.type_array, Op.type_runtime_array, Op.type_vector, Op.type_matrix => {
                const e = g.elemOf(t, 0);
                const stride: u32 = if (bytes) switch (g.tyOp(t)) {
                    Op.type_vector => if (g.isHalf(t)) 2 else 4,
                    Op.type_matrix => p.mstride,
                    else => g.s.defs[t].stride,
                } else g.unit(p.space) * g.comps(e);
                if (bytes and stride == 0) return g.bad("spirv: an array in a block without ArrayStride", .{});
                if (ixa == .imm) {
                    p.imm += ixa.imm * stride;
                } else {
                    if (p.space == .func and p.lo == p.hi) {
                        p.lo = p.imm;
                        p.hi = p.imm + g.lenOf(t) * stride;
                    }
                    if (p.space == .input) return g.unsupported("spirv: a dynamic index into a built-in", .{});
                    p.off = g.iadd(p.off, g.imul(ixa, u(stride)));
                }
                p.ty = e;
            },
            else => return g.bad("spirv: an access chain into type op {d}", .{g.tyOp(t)}),
        }
        return p;
    }

    /// The offset unit of a space's non-block layout: bytes for shared memory, components otherwise.
    fn unit(g: *const Gen, space: Space) u32 {
        _ = g;
        return if (space == .shared) 4 else 1;
    }

    fn loadPtr(g: *Gen, p: Ptr) Error!Comps {
        const k = g.k;
        switch (p.space) {
            .buffer, .push => {
                const n = try g.layout(p.ty, 0, p.mstride, 0);
                const c = try g.newComps(n);
                for (0..n) |j| {
                    const off = g.s.lay_off[j];
                    const ty = g.s.lay_ty[j];
                    if (ty == .pred) return g.bad("spirv: a bool in a block", .{});
                    g.slice(c)[j] = if (ty == .f16)
                        (if (p.space == .buffer) g.bufLoadHalf(p.slot, p.off, p.imm + off) else g.unhalf(try g.pushHalf(p.off, p.imm + off)))
                    else if (p.space == .buffer) g.bufLoad(p.slot, p.off, p.imm + off, ty) else try g.pushLoad(p.off, p.imm + off, ty);
                }
                return c;
            },
            .shared => {
                var tys: [MAX_DYNAMIC]kir.Ty = undefined;
                const n = try g.compTys(p.ty, &tys);
                const c = try g.newComps(n);
                for (0..n) |j| {
                    const ty = if (tys[j] == .pred) kir.Ty.u32 else tys[j];
                    var m = kir.shared(32);
                    const a = g.sharedAddr(p, @intCast(j), &m);
                    const v = r(k.load(ty, m, a));
                    g.slice(c)[j] = if (tys[j] == .pred) g.icmp(.u32, .ne, v, u(0)) else v;
                }
                return c;
            },
            .func => {
                var tys: [MAX_DYNAMIC]kir.Ty = undefined;
                const n = try g.compTys(p.ty, &tys);
                const c = try g.newComps(n);
                for (0..n) |j| {
                    if (p.off == .imm) {
                        const src: V = @enumFromInt(p.slot + p.imm + p.off.imm + @as(u32, @intCast(j)));
                        g.slice(c)[j] = r(k.mov(tys[j], r(src)));
                    } else {
                        if (p.hi - p.lo > MAX_DYNAMIC) return g.unsupported("spirv: a dynamically indexed variable of more than {d} components", .{MAX_DYNAMIC});
                        var res: Arg = u(0);
                        var pos = p.lo;
                        while (pos < p.hi) : (pos += 1) {
                                const jj: u32 = @intCast(j);
                            if (pos < p.imm + jj) continue;
                            const want = pos - p.imm - jj;
                            const src: V = @enumFromInt(p.slot + pos);
                            res = g.sel(tys[j], g.icmp(.u32, .eq, p.off, u(want)), r(src), res);
                        }
                        g.slice(c)[j] = if (res == .imm) res else r(k.mov(tys[j], res));
                    }
                }
                return c;
            },
            .handle => {
                const c = try g.newComps(1);
                g.slice(c)[0] = u(p.slot);
                return c;
            },
            .input => {
                const in_v = for (g.inputs[0..g.n_inputs]) |iv| {
                    if (iv.id == p.slot) break iv;
                } else return error.BadSpirv;
                const n = g.comps(p.ty);
                const src = g.slice(in_v.comps);
                if (p.imm + n > src.len) return error.BadSpirv;
                const c = try g.newComps(n);
                @memcpy(g.slice(c), src[p.imm..][0..n]);
                return c;
            },
        }
    }

    fn storePtr(g: *Gen, p: Ptr, vals: []const Arg) Error!void {
        const k = g.k;
        switch (p.space) {
            .buffer => {
                const n = try g.layout(p.ty, 0, p.mstride, 0);
                if (n != vals.len) return error.BadSpirv;
                for (0..n) |j| {
                    if (g.s.lay_ty[j] == .f16) g.bufStoreHalf(p.slot, p.off, p.imm + g.s.lay_off[j], vals[j]) else g.bufStore(p.slot, p.off, p.imm + g.s.lay_off[j], g.s.lay_ty[j], vals[j]);
                }
            },
            .push, .input, .handle => return g.bad("spirv: a store to a read-only variable", .{}),
            .shared => {
                var tys: [MAX_DYNAMIC]kir.Ty = undefined;
                const n = try g.compTys(p.ty, &tys);
                if (n != vals.len) return error.BadSpirv;
                for (0..n) |j| {
                    var m = kir.shared(32);
                    const a = g.sharedAddr(p, @intCast(j), &m);
                    const ty = if (tys[j] == .pred) kir.Ty.u32 else tys[j];
                    const v = if (tys[j] == .pred) g.sel(.u32, vals[j], u(1), u(0)) else vals[j];
                    k.store(ty, m, a, r(g.reg(v, ty)));
                }
            },
            .func => {
                var tys: [MAX_DYNAMIC]kir.Ty = undefined;
                const n = try g.compTys(p.ty, &tys);
                if (n != vals.len) return error.BadSpirv;
                if (p.off == .imm) {
                    for (0..n) |j| {
                        const dst: V = @enumFromInt(p.slot + p.imm + p.off.imm + @as(u32, @intCast(j)));
                        k.set(dst, .mov, vals[j], no, no);
                    }
                } else {
                    if (p.hi - p.lo > MAX_DYNAMIC) return g.unsupported("spirv: a dynamically indexed variable of more than {d} components", .{MAX_DYNAMIC});
                    // each element the index may name: keep it, or take the value
                    var pos = p.lo;
                    while (pos < p.hi) : (pos += 1) {
                        const dst: V = @enumFromInt(p.slot + pos);
                        for (0..n) |j| {
                            const jj: u32 = @intCast(j);
                            if (pos < p.imm + jj) continue;
                            const want = pos - p.imm - jj;
                            const hit = g.icmp(.u32, .eq, p.off, u(want));
                            const v = g.sel(tys[j], hit, vals[j], r(dst));
                            if (!(v == .reg and v.reg == dst)) k.set(dst, .mov, v, no, no);
                        }
                    }
                }
            },
        }
    }

    fn sharedAddr(g: *Gen, p: Ptr, j: u32, m: *kir.Mem) Arg {
        const imm = p.imm + 4 * j;
        if (p.off == .imm) return u(p.off.imm + imm);
        if (imm < (1 << 18)) {
            m.imm = @intCast(imm);
            return p.off;
        }
        return g.iadd(p.off, u(imm));
    }

    /// A 32-bit load from binding b at off + imm (checked against its range when robust).
    fn bufLoad(g: *Gen, b: u32, off: Arg, imm: u32, ty: kir.Ty) Arg {
        const k = g.k;
        const total = g.iadd(off, u(imm));
        if (!g.opts.robust) {
            return r(k.load(ty, kir.global(g.kbinding(b), 32), g.iadd(g.view[b], total)));
        }
        const inb = g.icmp(.u32, .lt, total, g.lim[b]);
        const a = g.iadd(g.view[b], g.sel(.u32, inb, total, u(0)));
        const v = r(k.load(ty, kir.global(g.kbinding(b), 32), a));
        return g.sel(ty, inb, v, u(0));
    }

    fn bufStore(g: *Gen, b: u32, off: Arg, imm: u32, ty: kir.Ty, v: Arg) void {
        const k = g.k;
        const total = g.iadd(off, u(imm));
        const val = r(g.reg(v, ty));
        if (!g.opts.robust) {
            k.store(ty, kir.global(g.kbinding(b), 32), g.iadd(g.view[b], total), val);
            return;
        }
        const inb = g.icmp(.u32, .lt, total, g.lim[b]);
        k.ifp(inb);
        k.store(ty, kir.global(g.kbinding(b), 32), g.iadd(g.view[b], total), val);
        k.endif();
    }

    /// A half from binding b at off + imm (16 bits; 0 out of range when
    /// robust), as an f32.
    fn bufLoadHalf(g: *Gen, b: u32, off: Arg, imm: u32) Arg {
        const k = g.k;
        const total = g.iadd(off, u(imm));
        if (!g.opts.robust) return r(k.cvt(.f16, .f32, .rne, r(k.load(.f16, kir.global(g.kbinding(b), 16), g.iadd(g.view[b], total)))));
        const inb = g.icmp(.u32, .lt, total, g.iop(.isub, .u32, g.iop(.imax, .u32, g.range[b], u(2)), u(1)));
        const a = g.iadd(g.view[b], g.sel(.u32, inb, total, u(0)));
        const v = r(k.cvt(.f16, .f32, .rne, r(k.load(.f16, kir.global(g.kbinding(b), 16), a))));
        return g.sel(.f32, inb, v, f(0));
    }

    /// A half (an f32 holding one) stored as 16 bits.
    fn bufStoreHalf(g: *Gen, b: u32, off: Arg, imm: u32, v: Arg) void {
        const k = g.k;
        const total = g.iadd(off, u(imm));
        const h = r(k.cvt(.f32, .f16, .rne, r(g.reg(v, .f32))));
        if (!g.opts.robust) {
            k.store(.f16, kir.global(g.kbinding(b), 16), g.iadd(g.view[b], total), h);
            return;
        }
        const inb = g.icmp(.u32, .lt, total, g.iop(.isub, .u32, g.iop(.imax, .u32, g.range[b], u(2)), u(1)));
        k.ifp(inb);
        k.store(.f16, kir.global(g.kbinding(b), 16), g.iadd(g.view[b], total), h);
        k.endif();
    }

    /// A push constant's half: the 16 bits of its word (as a u32).
    fn pushHalf(g: *Gen, off: Arg, imm: u32) Error!Arg {
        if (off == .imm) {
            const at = off.imm + imm;
            const w = try g.pushLoad(u(at & ~@as(u32, 3)), 0, .u32);
            return g.iop(.@"and", .u32, g.iop(.shr, .u32, w, u(8 * (at & 2))), u(0xffff));
        }
        const at = g.iadd(off, u(imm));
        const w = try g.pushLoad(g.iop(.@"and", .u32, at, u(~@as(u32, 3))), 0, .u32);
        return g.iop(.@"and", .u32, g.iop(.shr, .u32, w, g.iop(.shl, .u32, g.iop(.@"and", .u32, at, u(2)), u(3))), u(0xffff));
    }

    /// A push-constant word: its parameter, or a choice among them for a dynamic offset.
    fn pushLoad(g: *Gen, off: Arg, imm: u32, ty: kir.Ty) Error!Arg {
        const base: u32 = 2 * @as(u32, g.info.n_bindings);
        const words = (g.info.push_bytes + 3) / 4;
        if (off == .imm) {
            const wi = (off.imm + imm) / 4;
            if (wi >= words) return u(0);
            return g.pushWord(ty, base, wi);
        }
        var res: Arg = u(0);
        for (0..words) |wi| {
            const at: u32 = @intCast(wi * 4);
            if (at < imm) continue;
            res = g.sel(ty, g.icmp(.u32, .eq, off, u(at - imm)), g.pushWord(ty, base, @intCast(wi)), res);
        }
        return res;
    }

    /// Push-constant word wi: a parameter (compute), or a word of the
    /// draw's uniform binding (a graphics stage).
    fn pushWord(g: *Gen, ty: kir.Ty, base: u32, wi: u32) Arg {
        if (g.io) |io| return r(g.uniWord(ty, io.word_push + wi));
        return r(g.k.param(ty, @intCast(base + wi)));
    }

    /// The KIR binding of buffer slot b.
    fn kbinding(g: *const Gen, b: u32) u8 {
        return if (g.io) |io| @intCast(io.buffers + b) else @intCast(b);
    }

    /// A word of the draw's uniform binding (a graphics stage).
    fn uniWord(g: *Gen, ty: kir.Ty, word: u32) V {
        var m = kir.global(g.io.?.uni, 32);
        m.imm = @intCast(word * 4);
        return g.k.load(ty, m, u(0));
    }

    // ── Graphics stages ──

    /// Emits entry point `entry_name` of a vertex or fragment stage
    /// (Options.stage) into `k`, the raster's kernel being built, through
    /// `io` (see the header). `res` gathers what the pipeline binds, or
    /// (frozen) names the slots the pipeline has. The kernel is not
    /// finished here: the raster goes on with it.
    pub fn emitStage(g: *Gen, entry_name: []const u8, k: *kir.Kernel, io: *StageIO, res: *Resources) Error!void {
        if (g.opts.stage == .compute) return g.bad("spirv: emitStage of a compute stage", .{});
        try g.parse(entry_name);
        g.k = k;
        g.io = io;
        g.res = res;
        try g.markUses();
        const stage = g.opts.stage;
        // buffers: the pipeline's slots, their views from the draw's words
        var id: u32 = 0;
        while (id < g.bound) : (id += 1) {
            const d = &g.s.defs[id];
            if (d.op != Op.variable or d.kbind != NONE - 1) continue;
            const sc = g.inst(d.at)[3];
            const want = Binding{ .set = if (d.set == NONE) 0 else d.set, .binding = if (d.binding == NONE) 0 else d.binding, .kind = if (sc == StorageClass.uniform) .uniform else .storage };
            const b = try g.bufSlot(want);
            d.kbind = b;
            g.view[b] = r(g.uniWord(.u32, io.word_views + 2 * b));
            g.range[b] = r(g.uniWord(.u32, io.word_views + 2 * b + 1));
            g.lim[b] = if (g.opts.robust) r(k.op2(.isub, .u32, r(k.op2(.imax, .u32, g.range[b], u(4))), u(3))) else u(0);
        }
        if (stage == .fragment) {
            g.discard = k.reg(.pred);
            k.set(g.discard, .mov, u(0), no, no);
        }
        id = 0;
        while (id < g.bound) : (id += 1) {
            const d = g.s.defs[id];
            if (d.op != Op.variable or d.kbind == NONE) continue;
            const in = g.inst(d.at);
            const t = g.elemOf(in[1], 0);
            switch (in[3]) {
                StorageClass.storage_buffer, StorageClass.uniform => {
                    g.s.vals[id] = .{ .ptr = .{ .space = .buffer, .slot = d.kbind, .ty = t } };
                },
                StorageClass.push_constant => {
                    g.push_var = id;
                    g.info.push_bytes = try g.blockBytes(t);
                    res.push_bytes = @max(res.push_bytes, g.info.push_bytes);
                    g.s.vals[id] = .{ .ptr = .{ .space = .push, .slot = 0, .ty = t } };
                },
                StorageClass.uniform_constant => g.s.vals[id] = .{ .ptr = .{ .space = .handle, .slot = id, .ty = t } },
                StorageClass.input => try g.stageInput(id, t),
                StorageClass.output => {
                    if (g.n_outs == g.outs.len) return error.TooBig;
                    try g.funcVar(id, t, if (in.len > 4) in[4] else NONE);
                    g.outs[g.n_outs] = .{ .id = id, .first = g.s.vals[id].ptr.slot, .ty = t };
                    g.n_outs += 1;
                },
                StorageClass.private => try g.funcVar(id, t, if (in.len > 4) in[4] else NONE),
                StorageClass.function => {},
                else => return g.unsupported("spirv: storage class {d} in a {s} shader", .{ in[3], @tagName(stage) }),
            }
        }
        g.wrap_entry = true;
        try g.call(g.entry, &.{}, false);
        try g.finishOutputs();
        if (stage == .fragment) io.discard = g.discard;
    }

    /// Buffer (set, binding)'s slot in the pipeline's list.
    fn bufSlot(g: *Gen, want: Binding) Error!u32 {
        const res = g.res.?;
        for (res.bufs[0..res.n_bufs], 0..) |b, i| {
            if (b.set == want.set and b.binding == want.binding) return @intCast(i);
        }
        if (res.frozen) return g.bad("spirv: buffer ({d}, {d}) is not the pipeline's", .{ want.set, want.binding });
        if (res.n_bufs == MAX_BINDINGS) return g.unsupported("spirv: more than {d} buffers", .{MAX_BINDINGS});
        res.bufs[res.n_bufs] = want;
        res.n_bufs += 1;
        return res.n_bufs - 1;
    }

    /// An Input variable of a graphics stage: a built-in, or a location's
    /// attribute (vertex) or varying (fragment).
    fn stageInput(g: *Gen, id: u32, t: u32) Error!void {
        const io = g.io.?;
        const res = g.res.?;
        const k = g.k;
        const d = g.s.defs[id];
        var vals: [4]Arg = undefined;
        var n: u32 = 1;
        if (d.builtin != NONE) {
            switch (d.builtin) {
                BuiltIn.vertex_index => vals[0] = g.iadd(r(io.vertex_id), r(g.uniWord(.u32, io.word_base_vertex))),
                BuiltIn.instance_index => vals[0] = g.iadd(r(io.instance_id), r(g.uniWord(.u32, io.word_base_instance))),
                BuiltIn.frag_coord => {
                    // (the raster's y is from the bottom; Vulkan's from the top)
                    n = 4;
                    vals[0] = r(io.frag_coord[0]);
                    vals[1] = r(k.op2(.fsub, .f32, r(g.uniWord(.f32, io.word_height)), r(io.frag_coord[1])));
                    vals[2] = r(io.frag_coord[2]);
                    vals[3] = r(io.frag_coord[3]);
                },
                BuiltIn.front_facing => vals[0] = r(io.front_facing),
                BuiltIn.sample_id => vals[0] = u(0),
                BuiltIn.helper_invocation => vals[0] = u(0),
                else => return g.unsupported("spirv: input built-in {d} in a {s} shader", .{ d.builtin, @tagName(g.opts.stage) }),
            }
            if (g.comps(t) != n) return g.bad("spirv: built-in {d} of the wrong type", .{d.builtin});
        } else {
            if (d.location == NONE) return g.unsupported("spirv: an Input variable with neither a built-in nor a location", .{});
            var tys: [16]kir.Ty = undefined;
            n = try g.compTys(t, &tys);
            if (n == 0 or d.component + n > 4) return g.unsupported("spirv: an input of {d} components at location {d}", .{ n, d.location });
            const loc = d.location;
            for (0..n) |j| {
                const c = d.component + @as(u32, @intCast(j));
                const src: V = if (g.opts.stage == .vertex) blk: {
                    if (loc >= MAX_ATTRS) return g.unsupported("spirv: vertex input location {d}", .{loc});
                    break :blk io.attr.?[loc][c];
                } else blk: {
                    if (loc * 4 + c >= MAX_VARYINGS) return g.unsupported("spirv: varying location {d}", .{loc});
                    break :blk io.varying_in.?[loc * 4 + c];
                };
                // (an attribute's register holds f32 bits or an integer's: as the type says)
                vals[j] = if (k.tys[@intFromEnum(src)] == tys[j]) r(src) else r(k.mov(tys[j], r(src)));
            }
            if (g.opts.stage == .vertex) {
                res.attrs |= @as(u32, 1) << @intCast(loc);
            } else {
                res.varyings_in = @max(res.varyings_in, @as(u8, @intCast(4 * (loc + 1))));
                if (d.flat or tys[0] != .f32) {
                    for (0..n) |j| res.flat |= @as(u64, 1) << @intCast(loc * 4 + d.component + j);
                }
            }
        }
        if (g.n_inputs == g.inputs.len) return error.TooBig;
        const c = try g.newComps(n);
        @memcpy(g.slice(c), vals[0..n]);
        g.inputs[g.n_inputs] = .{ .id = id, .comps = c };
        g.n_inputs += 1;
        g.s.vals[id] = .{ .ptr = .{ .space = .input, .slot = id, .ty = t } };
    }

    /// The Output variables' registers handed to the raster: the position
    /// and varyings (vertex), the colour and the discard (fragment).
    fn finishOutputs(g: *Gen) Error!void {
        const io = g.io.?;
        const res = g.res.?;
        const k = g.k;
        for (g.outs[0..g.n_outs]) |o| {
            const d = g.s.defs[o.id];
            if (g.tyOp(o.ty) == Op.type_struct) {
                // (glslang's gl_PerVertex: built-in members)
                var at: u32 = 0;
                for (0..g.lenOf(o.ty)) |m| {
                    const mt = g.elemOf(o.ty, @intCast(m));
                    try g.outBuiltin(g.member(o.ty, @intCast(m)).builtin, o.first + at, g.comps(mt));
                    at += g.comps(mt);
                }
                continue;
            }
            if (d.builtin != NONE) {
                try g.outBuiltin(d.builtin, o.first, g.comps(o.ty));
                continue;
            }
            if (d.location == NONE) return g.unsupported("spirv: an Output variable with neither a built-in nor a location", .{});
            const n = g.comps(o.ty);
            if (n == 0 or d.component + n > 4) return g.unsupported("spirv: an output of {d} components at location {d}", .{ n, d.location });
            for (0..n) |j| {
                const src: V = @enumFromInt(o.first + j);
                const c = d.component + @as(u32, @intCast(j));
                const v = if (k.tys[@intFromEnum(src)] == .f32) src else k.mov(.f32, r(src));
                if (g.opts.stage == .vertex) {
                    const slot = d.location * 4 + c;
                    if (slot >= MAX_VARYINGS) return g.unsupported("spirv: varying location {d}", .{d.location});
                    io.varying_out[slot] = v;
                    res.varyings_out = @max(res.varyings_out, @as(u8, @intCast(4 * (d.location + 1))));
                    if (d.flat) res.flat |= @as(u64, 1) << @intCast(slot);
                } else {
                    res.outputs |= @as(u32, 1) << @intCast(d.location);
                    if (d.location == io.color_loc) io.color[c] = v;
                }
            }
        }
        // (what no output wrote reads 0)
        const fill = if (g.opts.stage == .vertex) io.position[0..] else io.color[0..];
        for (fill) |*x| {
            if (x.* == .none) x.* = k.mov(.f32, f(0));
        }
        if (g.opts.stage == .fragment and io.srgb) {
            for (io.color[0..3]) |*x| x.* = g.srgbEncode(x.*);
        }
    }

    /// Linear to sRGB (IEC 61966-2-1), clamped to [0, 1].
    fn srgbEncode(g: *Gen, x: V) V {
        const k = g.k;
        const c = g.fop(.fmin, g.fop(.fmax, r(x), f(0)), f(1));
        const lo = g.fop(.fmul, c, f(12.92));
        const p = g.fop1(.fexp2, g.fop(.fmul, g.fop1(.flog2, c), f(1.0 / 2.4)));
        const hi = g.fop(.fsub, g.fop(.fmul, p, f(1.055)), f(0.055));
        const v = g.sel(.f32, g.fcmp(.le, c, f(0.0031308)), lo, hi);
        return if (v == .reg) v.reg else k.mov(.f32, v);
    }

    fn outBuiltin(g: *Gen, bi: u32, first: u32, n: u32) Error!void {
        const io = g.io.?;
        switch (bi) {
            BuiltIn.position => {
                if (n != 4) return error.BadSpirv;
                for (0..4) |j| io.position[j] = @enumFromInt(first + j);
            },
            // (points are drawn one pixel; no clip planes yet)
            BuiltIn.point_size, BuiltIn.clip_distance, BuiltIn.cull_distance, BuiltIn.sample_mask, NONE => {},
            BuiltIn.frag_depth => return g.unsupported("spirv: FragDepth (the raster keeps the interpolated depth)", .{}),
            else => return g.unsupported("spirv: output built-in {d}", .{bi}),
        }
    }

    /// The texture slot an image (and its sampler) value names.
    /// Whether type `t` is a storage image (OpTypeImage, Sampled 2).
    fn isStorageImage(g: *Gen, t: u32) bool {
        if (t >= g.bound or g.tyOp(t) != Op.type_image) return false;
        const ti = g.tyInst(t);
        return ti.len >= 9 and ti[7] == 2;
    }

    /// A compute shader's storage image op (see the header): OpImageRead,
    /// OpImageWrite, OpImageQuerySize(Lod).
    fn storageImageOp(g: *Gen, op: u16, in: []const u32) Error!void {
        if (g.io != null) return g.unsupported("spirv: storage images in a {s} shader", .{@tagName(g.opts.stage)});
        const k = g.k;
        const h = try g.get(if (op == Op.image_write) in[1] else in[3]);
        if (h.len == 0 or h[0] != .imm or h[0].imm >= g.bound) return g.bad("spirv: an image that is not a variable's", .{});
        const iv = g.s.defs[h[0].imm];
        if (iv.op != Op.variable) return g.bad("spirv: an image that is not a variable's", .{});
        const it = g.elemOf(g.inst(iv.at)[1], 0);
        if (!g.isStorageImage(it) or iv.kbind >= MAX_BINDINGS) {
            return g.unsupported("spirv: image op {d} on a sampled image in a compute shader", .{op});
        }
        const ti = g.tyInst(it);
        const dim: Dim = @enumFromInt(@as(u8, @intCast(@min(ti[3], 6))));
        if (dim != .d1 and dim != .d2 and dim != .d3) return g.unsupported("spirv: storage images of dimension {s}", .{@tagName(dim)});
        if (ti[6] != 0) return g.unsupported("spirv: multisampled storage images", .{});
        const arrayed = ti[5] != 0;
        const fmt = storageFormat(ti[8]) orelse return g.unsupported("spirv: storage image format {d}", .{ti[8]});
        const b = iv.kbind;
        const w0 = g.info.imageWord(b);
        const pitch = r(k.param(.u32, @intCast(w0)));
        const lpitch = r(k.param(.u32, @intCast(w0 + 1)));
        const wh = r(k.param(.u32, @intCast(w0 + 2)));
        const layers = r(k.param(.u32, @intCast(w0 + 3)));
        const width = g.iop(.@"and", .u32, wh, u(0xffff));
        const height = g.iop(.shr, .u32, wh, u(16));
        switch (op) {
            Op.image_query_size, Op.image_query_size_lod => {
                const all: [3]Arg = switch (dim) {
                    .d1 => .{ width, layers, u(0) },
                    else => .{ width, height, layers },
                };
                const n = g.comps(in[1]);
                if (n > 3) return error.BadSpirv;
                try g.define(in[2], all[0..n]);
                return;
            },
            Op.image_read, Op.image_write => {},
            else => return g.unsupported("spirv: image op {d} on a storage image", .{op}),
        }
        // the texel: (x, y, layer or z), in the image or not
        const c = try g.get(if (op == Op.image_write) in[2] else in[4]);
        const x = c[0];
        var y: Arg = u(0);
        var z: Arg = u(0);
        switch (dim) {
            .d1 => if (arrayed and c.len > 1) {
                z = c[1];
            },
            .d2 => {
                if (c.len > 1) y = c[1];
                if (arrayed and c.len > 2) z = c[2];
            },
            else => {
                if (c.len > 1) y = c[1];
                if (c.len > 2) z = c[2];
            },
        }
        const inb = g.pand(g.pand(g.icmp(.u32, .lt, x, width), g.icmp(.u32, .lt, y, if (dim == .d1) u(1) else height)), g.icmp(.u32, .lt, z, layers));
        const bytes: u32 = if (fmt.unorm8) 4 else 4 * @as(u32, fmt.comps);
        const zs = if (z == .imm and z.imm == 0) u(0) else g.imul(z, lpitch);
        const yp = if (y == .imm and y.imm == 0) u(0) else g.imul(y, pitch);
        const at = g.iadd(g.iadd(zs, yp), g.imul(x, u(bytes)));
        const mem = kir.global(g.kbinding(b), 32);
        if (op == Op.image_read) {
            const safe = g.iadd(g.view[b], g.sel(.u32, inb, at, u(0)));
            const one: Arg = if (fmt.ty == .f32) f(1.0) else u(1);
            var out: [4]Arg = .{ u(0), u(0), u(0), one };
            if (fmt.ty == .f32) {
                out[0] = f(0);
                out[1] = f(0);
                out[2] = f(0);
            }
            if (fmt.unorm8) {
                const word = r(k.load(.u32, mem, safe));
                for (0..4) |j| {
                    const byte = g.iop(.@"and", .u32, g.iop(.shr, .u32, word, u(@intCast(8 * j))), u(0xff));
                    out[j] = g.fop(.fmul, r(g.k.cvt(.u32, .f32, .rne, byte)), f(1.0 / 255.0));
                }
            } else {
                for (0..fmt.comps) |j| out[j] = r(k.load(fmt.ty, mem, g.iadd(safe, u(@intCast(4 * j)))));
            }
            const zero: Arg = if (fmt.ty == .f32) f(0) else u(0);
            for (&out) |*o| o.* = g.sel(fmt.ty, inb, o.*, zero);
            const n = g.comps(in[1]);
            if (n > 4) return error.BadSpirv;
            try g.define(in[2], out[0..n]);
            return;
        }
        // a write: the texel's first components, in the image only
        const texel = try g.get(in[3]);
        const addr = g.iadd(g.view[b], at);
        k.ifp(inb);
        if (fmt.unorm8) {
            var word: Arg = u(0);
            for (0..4) |j| {
                const v = if (j < texel.len) texel[j] else f(0);
                const cl = g.fop(.fmin, g.fop(.fmax, v, f(0)), f(1));
                const q = r(g.k.cvt(.f32, .u32, .rz, g.fop(.fadd, g.fop(.fmul, cl, f(255.0)), f(0.5))));
                word = g.iop(.@"or", .u32, word, g.iop(.shl, .u32, q, u(@intCast(8 * j))));
            }
            k.store(.u32, mem, addr, r(g.reg(word, .u32)));
        } else {
            for (0..fmt.comps) |j| {
                const v0 = if (j < texel.len) texel[j] else u(0);
                // (what the narrow format holds: its rounding, its bits)
                const v = switch (fmt.quant) {
                    .none => v0,
                    .snorm8 => blk: {
                        const cl = g.fop(.fmin, g.fop(.fmax, v0, f(-1)), f(1));
                        break :blk g.fop(.fdiv, g.fop1(.frne, g.fop(.fmul, cl, f(127))), f(127));
                    },
                    .u8 => g.iop(.@"and", .u32, v0, u(0xff)),
                    .u16 => g.iop(.@"and", .u32, v0, u(0xffff)),
                    .s8 => r(g.k.op3(.bfe, .i32, r(g.reg(v0, .i32)), u(0), u(8))),
                    .s16 => r(g.k.op3(.bfe, .i32, r(g.reg(v0, .i32)), u(0), u(16))),
                };
                k.store(fmt.ty, mem, g.iadd(addr, u(@intCast(4 * j))), r(g.reg(v, fmt.ty)));
            }
        }
        k.endif();
    }

    fn imageRef(g: *Gen, h: []const Arg) Error!ImageRef {
        const res = g.res orelse return g.unsupported("spirv: images in a compute shader", .{});
        if (h.len == 0 or h[0] != .imm or h[0].imm >= g.bound) return g.bad("spirv: an image that is not a variable's", .{});
        const iv = g.s.defs[h[0].imm];
        if (iv.op != Op.variable) return g.bad("spirv: an image that is not a variable's", .{});
        const it = g.elemOf(g.inst(iv.at)[1], 0);
        if (g.tyOp(it) != Op.type_image) return g.bad("spirv: %{d} is not an image", .{h[0].imm});
        const ti = g.tyInst(it);
        if (ti.len < 9) return error.BadSpirv;
        // (a multisampled image: src/vk keeps one sample a pixel, so a
        // fetch's Sample operand reads that one)
        const st = g.tyInst(ti[2]);
        const kind: SampleKind = if (g.tyOp(ti[2]) == Op.type_float) .float else if (st.len > 3 and st[3] != 0) .int else .uint;
        const want = TexSlot{
            .image = .{ .set = if (iv.set == NONE) 0 else iv.set, .binding = if (iv.binding == NONE) 0 else iv.binding },
            .sampler = .{ .set = 0, .binding = 0 },
            .has_sampler = h.len > 1,
        };
        var slot = want;
        if (h.len > 1) {
            if (h[1] != .imm or h[1].imm >= g.bound) return error.BadSpirv;
            const sv = g.s.defs[h[1].imm];
            slot.sampler = .{ .set = if (sv.set == NONE) 0 else sv.set, .binding = if (sv.binding == NONE) 0 else sv.binding };
        }
        const n: u32 = for (res.tex[0..res.n_tex], 0..) |x, i| {
            if (x.has_sampler == slot.has_sampler and x.image.set == slot.image.set and x.image.binding == slot.image.binding and
                (!x.has_sampler or (x.sampler.set == slot.sampler.set and x.sampler.binding == slot.sampler.binding))) break @intCast(i);
        } else blk: {
            if (res.frozen) return g.bad("spirv: a texture the pipeline does not have", .{});
            if (res.n_tex == MAX_TEX) return g.unsupported("spirv: more than {d} textures", .{MAX_TEX});
            res.tex[res.n_tex] = slot;
            res.n_tex += 1;
            break :blk res.n_tex - 1;
        };
        var ref = ImageRef{ .slot = n, .dim = @enumFromInt(@as(u8, @intCast(@min(ti[3], 6)))), .arrayed = ti[5] != 0, .depth = ti[4] == 1, .kind = kind };
        if (g.io == null) {
            if (n >= g.info.tex_room) return g.unsupported("spirv: more image and sampler pairs than images", .{});
            ref.bind = g.info.tex_first + @as(u8, @intCast(n));
            ref.uni = g.info.tex_uni;
        }
        return ref;
    }

    /// The coordinates a dimension has (before an array's layer).
    fn coordsOf(dim: Dim) u32 {
        return switch (dim) {
            .d1, .buffer => 1,
            .d3, .cube => 3,
            else => 2,
        };
    }

    fn imageOp(g: *Gen, op: u16, in: []const u32) Error!void {
        // (compute: a storage image's ops, or a sampled one's through
        // Options.tex)
        if (g.io == null) {
            const h = try g.get(in[3]);
            if (h.len == 0 or h[0] != .imm or h[0].imm >= g.bound) return g.bad("spirv: an image that is not a variable's", .{});
            const iv = g.s.defs[h[0].imm];
            if (iv.op != Op.variable or g.isStorageImage(g.elemOf(g.inst(iv.at)[1], 0))) return g.storageImageOp(op, in);
        }
        const k = g.k;
        var img = try g.imageRef(try g.get(in[3]));
        const tex = (if (g.io) |io| io.tex else g.opts.tex) orelse return g.unsupported("spirv: images without a texture unit", .{});
        const n = g.comps(in[1]);
        var out: [4]Arg = .{ u(0), u(0), u(0), u(0) };
        switch (op) {
            Op.image_query_size_lod, Op.image_query_size => {
                const lod = if (op == Op.image_query_size_lod) (try g.get(in[4]))[0] else u(0);
                const sz = tex.size(tex.ctx, k, img, lod);
                out[0] = sz[0];
                out[1] = sz[1];
                out[2] = sz[2];
            },
            Op.image_query_levels => out[0] = tex.levels(tex.ctx, k, img),
            Op.image_query_samples => out[0] = u(1),
            Op.image_fetch => {
                const c = try g.get(in[4]);
                var cs: [4]Arg = .{ u(0), u(0), u(0), u(0) };
                for (c[0..@min(c.len, 4)], 0..) |x, j| cs[j] = x;
                var lod: Arg = u(0);
                if (in.len > 6 and in[5] & 2 != 0) lod = (try g.get(in[6]))[0];
                out = tex.fetch(tex.ctx, k, img, cs, lod);
            },
            else => {
                const dref = op == Op.image_sample_dref_implicit_lod or op == Op.image_sample_dref_explicit_lod;
                const implicit = op == Op.image_sample_implicit_lod or op == Op.image_sample_dref_implicit_lod;
                const c = try g.get(in[4]);
                var cs: [4]Arg = .{ f(0), f(0), f(0), f(0) };
                for (c[0..@min(c.len, 4)], 0..) |x, j| cs[j] = x;
                var at: usize = 5;
                if (dref) {
                    img.compare = (try g.get(in[5]))[0];
                    at = 6;
                }
                var bias: Arg = f(0);
                var lod: Lod = .base;
                var offset: [3]i32 = .{ 0, 0, 0 };
                if (at < in.len) {
                    const mask = in[at];
                    var x = at + 1;
                    if (mask & 0x1 != 0) {
                        bias = (try g.get(in[x]))[0];
                        x += 1;
                    }
                    if (mask & 0x2 != 0) {
                        lod = .{ .level = (try g.get(in[x]))[0] };
                        x += 1;
                    }
                    if (mask & 0x4 != 0) {
                        const dx = try g.get(in[x]);
                        const dy = try g.get(in[x + 1]);
                        var gr: Lod = .{ .grad = .{ .dx = .{ f(0), f(0), f(0) }, .dy = .{ f(0), f(0), f(0) }, .bias = f(0) } };
                        for (0..@min(dx.len, 3)) |j| gr.grad.dx[j] = dx[j];
                        for (0..@min(dy.len, 3)) |j| gr.grad.dy[j] = dy[j];
                        lod = gr;
                        x += 2;
                    }
                    if (mask & 0x8 != 0) {
                        const o = try g.get(in[x]);
                        for (0..@min(o.len, 3)) |j| {
                            if (o[j] != .imm) return g.bad("spirv: a ConstOffset that is not constant", .{});
                            offset[j] = @bitCast(o[j].imm);
                        }
                        x += 1;
                    }
                    if (mask & ~@as(u32, 0xf) != 0) return g.unsupported("spirv: image operands 0x{x}", .{mask});
                }
                if (implicit and img.kind == .float and g.io != null) {
                    // a fragment shader's: from the coordinates' derivatives
                    const nc = coordsOf(img.dim);
                    var gr: Lod = .{ .grad = .{ .dx = .{ f(0), f(0), f(0) }, .dy = .{ f(0), f(0), f(0) }, .bias = bias } };
                    if (g.opts.stage == .fragment) {
                        for (0..nc) |j| {
                            gr.grad.dx[j] = g.deriv(cs[j], false);
                            gr.grad.dy[j] = g.deriv(cs[j], true);
                        }
                        lod = gr;
                    } else lod = .base;
                }
                out = tex.sample(tex.ctx, k, img, cs, lod, offset);
            },
        }
        if (n > 4) return error.BadSpirv;
        try g.define(in[2], out[0..n]);
    }

    /// d/dx (across) or d/dy (up) of a fragment shader's value: its
    /// difference with the quad's neighbour (0 outside whole quads: the
    /// pipeline learns it must run them).
    fn deriv(g: *Gen, x: Arg, up: bool) Arg {
        if (g.opts.stage != .fragment) return f(0);
        g.res.?.quads = true;
        const io = g.io.?;
        if (!io.quads or x == .imm) return f(0);
        const k = g.k;
        const xv = if (x == .reg and k.tys[@intFromEnum(x.reg)] == .f32) x.reg else k.mov(.f32, x);
        const o = k.shfl(.f32, .xor, r(xv), u(if (up) io.quad_y else io.quad_x));
        const odd = if (up) io.odd_y else io.odd_x;
        // (the raster's y is up, Vulkan's down: dy is the other way)
        const d = k.sel(.f32, r(odd), r(k.op2(.fsub, .f32, r(xv), r(o))), r(k.op2(.fsub, .f32, r(o), r(xv))));
        return if (up) r(k.op1(.fneg, .f32, r(d))) else r(d);
    }

    fn derivative(g: *Gen, op: u16, in: []const u32) Error!void {
        const a = try g.get(in[3]);
        const c = try g.newComps(@intCast(a.len));
        const k = g.k;
        for (a, g.slice(c)) |x, *o| {
            o.* = switch (op) {
                Op.dpdx, Op.dpdx_fine, Op.dpdx_coarse => g.deriv(x, false),
                Op.dpdy, Op.dpdy_fine, Op.dpdy_coarse => g.deriv(x, true),
                else => blk: {
                    const dx = g.deriv(x, false);
                    const dy = g.deriv(x, true);
                    if (dx == .imm and dy == .imm) break :blk f(0);
                    break :blk r(k.op2(.fadd, .f32, r(k.op1(.fabs, .f32, dx)), r(k.op1(.fabs, .f32, dy))));
                },
            };
        }
        g.setVal(in[2], c);
    }


    fn atomic(g: *Gen, op: u16, in: []const u32) Error!void {
        const k = g.k;
        const ty = try g.scalarTy(in[1]);
        if (ty != .u32 and ty != .i32) return g.unsupported("spirv: float atomics", .{});
        const p = try g.ptrOf(in[3]);
        // (compare-exchange: Value at 7, Comparator at 8, after two semantics)
        const cas = op == Op.atomic_compare_exchange or op == Op.atomic_compare_exchange_weak;
        const val: Arg = switch (op) {
            Op.atomic_i_increment => u(1),
            Op.atomic_load => u(0),
            Op.atomic_i_decrement => u(0xffff_ffff),
            Op.atomic_i_sub => g.op1(.ineg, .i32, (try g.get(in[6]))[0]),
            Op.atomic_compare_exchange, Op.atomic_compare_exchange_weak => (try g.get(in[7]))[0],
            else => (try g.get(in[6]))[0],
        };
        const kind: kir.Atom = switch (op) {
            Op.atomic_s_min, Op.atomic_u_min => .min,
            Op.atomic_s_max, Op.atomic_u_max => .max,
            Op.atomic_exchange => .xchg,
            Op.atomic_and => .@"and",
            Op.atomic_or => .@"or",
            Op.atomic_xor => .xor,
            else => .add,
        };
        const aty: kir.Ty = switch (op) {
            Op.atomic_s_min, Op.atomic_s_max => .i32,
            Op.atomic_u_min, Op.atomic_u_max => .u32,
            else => ty,
        };
        const v = r(g.reg(val, aty));
        const cmp: Arg = if (cas) r(g.reg((try g.get(in[8]))[0], aty)) else no;
        switch (p.space) {
            .shared => {
                var m = kir.shared(32);
                const a = g.sharedAddr(p, 0, &m);
                try g.define(in[2], &.{r(if (cas) k.cas(aty, m, a, cmp, v) else k.atomic(aty, kind, m, a, v))});
            },
            .buffer => {
                const total = g.iadd(p.off, u(p.imm));
                const m = kir.global(@intCast(p.slot), 32);
                if (!g.opts.robust) {
                    const a = g.iadd(g.view[p.slot], total);
                    try g.define(in[2], &.{r(if (cas) k.cas(aty, m, a, cmp, v) else k.atomic(aty, kind, m, a, v))});
                    return;
                }
                const inb = g.icmp(.u32, .lt, total, g.lim[p.slot]);
                const res = k.reg(aty);
                k.set(res, .mov, u(0), no, no);
                k.ifp(inb);
                if (cas)
                    k.setAux(res, .cas, g.iadd(g.view[p.slot], total), cmp, v, @bitCast(m))
                else
                    k.setAux(res, .atom, g.iadd(g.view[p.slot], total), v, u(@intFromEnum(kind)), @bitCast(m));
                k.endif();
                try g.define(in[2], &.{r(res)});
            },
            else => return g.unsupported("spirv: an atomic on storage of space {s}", .{@tagName(p.space)}),
        }
    }

    // ── Subgroups ──
    //
    // Over KIR's shfl, vote and ballot, for subgroups of 32 or fewer lanes.
    // Reductions and scans: a butterfly (shfl xor / up) when every lane of
    // the subgroup is active; otherwise a walk over the active lanes in
    // turn (shfl idx from each, under a uniform if), which never reads an
    // inactive lane.

    const GroupOp = struct {
        const reduce = 0;
        const inclusive = 1;
        const exclusive = 2;
        const clustered = 3;
    };

    /// The active lanes' mask (a ballot of true).
    fn activeMask(g: *Gen) Arg {
        return r(g.k.ballot(u(1), 0));
    }

    /// The lowest set bit's index (-1 for 0).
    fn lsb(g: *Gen, x0: Arg) Arg {
        const x = r(g.reg(x0, .u32));
        return g.findMsb(g.iop(.@"and", .u32, x, g.op1(.ineg, .i32, x)));
    }

    /// shfl of any scalar (a pred through 0/1).
    fn shflAny(g: *Gen, ty: kir.Ty, mode: kir.Shfl, x: Arg, b: Arg) Arg {
        if (ty == .pred) {
            const v = g.sel(.u32, x, u(1), u(0));
            return g.icmp(.u32, .ne, r(g.k.shfl(.u32, mode, r(g.reg(v, .u32)), b)), u(0));
        }
        return r(g.k.shfl(ty, mode, r(g.reg(x, ty)), b));
    }

    const Combine = struct { op: kir.Op, ty: kir.Ty, identity: u32 };

    fn combineOf(op: u16) Combine {
        return switch (op) {
            Op.group_non_uniform_i_add => .{ .op = .iadd, .ty = .u32, .identity = 0 },
            Op.group_non_uniform_f_add => .{ .op = .fadd, .ty = .f32, .identity = 0x8000_0000 },
            Op.group_non_uniform_i_mul => .{ .op = .imul, .ty = .u32, .identity = 1 },
            Op.group_non_uniform_f_mul => .{ .op = .fmul, .ty = .f32, .identity = 0x3f80_0000 },
            Op.group_non_uniform_s_min => .{ .op = .imin, .ty = .i32, .identity = 0x7fff_ffff },
            Op.group_non_uniform_u_min => .{ .op = .imin, .ty = .u32, .identity = 0xffff_ffff },
            Op.group_non_uniform_f_min => .{ .op = .fmin, .ty = .f32, .identity = 0x7f80_0000 },
            Op.group_non_uniform_s_max => .{ .op = .imax, .ty = .i32, .identity = 0x8000_0000 },
            Op.group_non_uniform_u_max => .{ .op = .imax, .ty = .u32, .identity = 0 },
            Op.group_non_uniform_f_max => .{ .op = .fmax, .ty = .f32, .identity = 0xff80_0000 },
            Op.group_non_uniform_bitwise_and, Op.group_non_uniform_logical_and => .{ .op = .@"and", .ty = .u32, .identity = 0xffff_ffff },
            Op.group_non_uniform_bitwise_or, Op.group_non_uniform_logical_or => .{ .op = .@"or", .ty = .u32, .identity = 0 },
            else => .{ .op = .xor, .ty = .u32, .identity = 0 },
        };
    }

    fn combine(g: *Gen, c: Combine, a: Arg, b: Arg) Arg {
        return switch (c.ty) {
            .f32 => g.fop(c.op, a, b),
            else => g.iop(c.op, c.ty, a, b),
        };
    }

    /// A reduction or scan of x (u32/i32/f32) over the active lanes.
    fn groupArith(g: *Gen, c: Combine, gop: u32, cluster: u32, x0: Arg) Error!Arg {
        const k = g.k;
        const width = g.opts.subgroup;
        const full: u32 = if (width >= 32) 0xffff_ffff else (@as(u32, 1) << @intCast(width)) - 1;
        const x = r(g.reg(x0, c.ty));
        const ln = r(k.lane());
        const res = k.reg(c.ty);
        k.ifp(g.icmp(.u32, .eq, g.activeMask(), u(full)));
        {
            var acc = x;
            switch (gop) {
                GroupOp.reduce, GroupOp.clustered => {
                    const n = if (gop == GroupOp.clustered) @min(cluster, width) else width;
                    var s: u32 = 1;
                    while (s < n) : (s *= 2) acc = g.combine(c, acc, r(k.shfl(c.ty, .xor, r(g.reg(acc, c.ty)), u(s))));
                },
                else => {
                    var s: u32 = 1;
                    while (s < width) : (s *= 2) {
                        const v = r(k.shfl(c.ty, .up, r(g.reg(acc, c.ty)), u(s)));
                        acc = g.sel(c.ty, g.icmp(.u32, .ge, ln, u(s)), g.combine(c, acc, v), acc);
                    }
                    if (gop == GroupOp.exclusive) {
                        const v = r(k.shfl(c.ty, .up, r(g.reg(acc, c.ty)), u(1)));
                        acc = g.sel(c.ty, g.icmp(.u32, .ge, ln, u(1)), v, u(c.identity));
                    }
                },
            }
            k.set(res, .mov, acc, no, no);
        }
        k.els();
        {
            const mask = g.activeMask();
            k.set(res, .mov, u(c.identity), no, no);
            const j = k.mov(.u32, u(0));
            k.loop();
            k.brk(g.icmp(.u32, .ge, r(j), u(width)));
            k.ifp(g.icmp(.u32, .ne, g.iop(.@"and", .u32, g.iop(.shr, .u32, mask, r(j)), u(1)), u(0)));
            const v = r(k.shfl(c.ty, .idx, x, r(j)));
            const take: Arg = switch (gop) {
                GroupOp.reduce => u(1),
                GroupOp.inclusive => g.icmp(.u32, .le, r(j), ln),
                GroupOp.exclusive => g.icmp(.u32, .lt, r(j), ln),
                else => g.icmp(.u32, .eq, g.iop(.@"and", .u32, g.iop(.xor, .u32, r(j), ln), u(~(@max(cluster, 1) - 1))), u(0)),
            };
            const both = g.combine(c, r(res), v);
            k.set(res, .mov, if (take == .imm) both else g.sel(c.ty, take, both, r(res)), no, no);
            k.endif();
            k.set(j, .iadd, r(j), u(1), no);
            k.endloop();
        }
        k.endif();
        return r(res);
    }

    fn subgroup(g: *Gen, op: u16, in: []const u32) Error!void {
        const k = g.k;
        if (g.opts.subgroup > 32) return g.unsupported("spirv: subgroup ops on a subgroup of {d}", .{g.opts.subgroup});
        const id = in[2];
        const rt = in[1];
        switch (op) {
            Op.group_non_uniform_elect => {
                try g.define(id, &.{g.icmp(.u32, .eq, r(k.lane()), g.lsb(g.activeMask()))});
            },
            Op.group_non_uniform_all, Op.group_non_uniform_any => {
                const p = (try g.get(in[4]))[0];
                const mode: kir.Vote = if (op == Op.group_non_uniform_all) .all else .any;
                try g.define(id, &.{if (p == .imm) p else r(k.vote(mode, p))});
            },
            Op.group_non_uniform_all_equal => {
                const xs = try g.get(in[4]);
                const ty = try g.scalarTy(g.typeOfValue(in[4]) orelse return error.BadSpirv);
                const first = g.lsb(g.activeMask());
                var same: Arg = u(1);
                for (xs) |x| {
                    const f0 = g.shflAny(ty, .idx, x, first);
                    const eq = switch (ty) {
                        .pred => g.pnot(g.pxor(x, f0)),
                        .f32 => g.fcmp(.eq, x, f0),
                        else => g.icmp(.u32, .eq, x, f0),
                    };
                    same = g.pand(same, eq);
                }
                try g.define(id, &.{if (same == .imm) same else r(k.vote(.all, same))});
            },
            Op.group_non_uniform_broadcast, Op.group_non_uniform_broadcast_first, Op.group_non_uniform_shuffle, Op.group_non_uniform_shuffle_xor, Op.group_non_uniform_shuffle_up, Op.group_non_uniform_shuffle_down, Op.group_non_uniform_quad_broadcast, Op.group_non_uniform_quad_swap => {
                const xs = try g.get(in[4]);
                const ty = try g.scalarTy(rt);
                var mode: kir.Shfl = .idx;
                const b: Arg = switch (op) {
                    Op.group_non_uniform_broadcast_first => g.lsb(g.activeMask()),
                    Op.group_non_uniform_quad_broadcast => g.iop(.@"or", .u32, g.iop(.@"and", .u32, r(k.lane()), u(~@as(u32, 3))), g.iop(.@"and", .u32, (try g.get(in[5]))[0], u(3))),
                    Op.group_non_uniform_quad_swap => blk: {
                        mode = .xor;
                        const dir = (try g.get(in[5]))[0];
                        if (dir != .imm) return g.bad("spirv: a QuadSwap direction not constant", .{});
                        break :blk u(dir.imm + 1);
                    },
                    else => blk: {
                        mode = switch (op) {
                            Op.group_non_uniform_shuffle_xor => .xor,
                            Op.group_non_uniform_shuffle_up => .up,
                            Op.group_non_uniform_shuffle_down => .down,
                            else => .idx,
                        };
                        break :blk (try g.get(in[5]))[0];
                    },
                };
                const c = try g.newComps(@intCast(xs.len));
                for (g.slice(c), xs) |*o, x| o.* = g.shflAny(ty, mode, x, b);
                g.setVal(id, c);
            },
            Op.group_non_uniform_ballot => {
                const p = (try g.get(in[4]))[0];
                try g.define(id, &.{ r(k.ballot(p, 0)), u(0), u(0), u(0) });
            },
            Op.group_non_uniform_inverse_ballot => {
                const v = (try g.get(in[4]))[0];
                try g.define(id, &.{g.icmp(.u32, .ne, g.iop(.@"and", .u32, g.iop(.shr, .u32, v, r(k.lane())), u(1)), u(0))});
            },
            Op.group_non_uniform_ballot_bit_extract => {
                const v = try g.get(in[4]);
                const ix = (try g.get(in[5]))[0];
                const bit = g.icmp(.u32, .ne, g.iop(.@"and", .u32, g.iop(.shr, .u32, v[0], ix), u(1)), u(0));
                try g.define(id, &.{g.pand(bit, g.icmp(.u32, .lt, ix, u(32)))});
            },
            Op.group_non_uniform_ballot_bit_count => {
                const v = (try g.get(in[5]))[0];
                const ln = r(k.lane());
                const below = g.sel(.u32, g.icmp(.u32, .eq, ln, u(0)), u(0), g.iop(.shr, .u32, u(0xffff_ffff), g.iop(.isub, .u32, u(32), ln)));
                const eq = g.iop(.shl, .u32, u(1), ln);
                const width = g.opts.subgroup;
                const full: u32 = if (width >= 32) 0xffff_ffff else (@as(u32, 1) << @intCast(width)) - 1;
                const m: Arg = switch (in[4]) {
                    GroupOp.inclusive => g.iop(.@"or", .u32, below, eq),
                    GroupOp.exclusive => below,
                    else => u(full),
                };
                try g.define(id, &.{g.popcount(g.iop(.@"and", .u32, v, m))});
            },
            Op.group_non_uniform_ballot_find_lsb => try g.define(id, &.{g.lsb((try g.get(in[4]))[0])}),
            Op.group_non_uniform_ballot_find_msb => try g.define(id, &.{g.findMsb((try g.get(in[4]))[0])}),
            else => {
                // the arithmetic: i/f add, mul, min, max; bitwise; logical
                const gop = in[4];
                const cluster: u32 = if (gop == GroupOp.clustered) blk: {
                    if (in.len < 7) return error.BadSpirv;
                    const cs = (try g.get(in[6]))[0];
                    if (cs != .imm or cs.imm == 0 or cs.imm & (cs.imm - 1) != 0) return g.bad("spirv: a ClusterSize not a constant power of two", .{});
                    break :blk cs.imm;
                } else 0;
                if (gop > GroupOp.clustered) return g.unsupported("spirv: group operation {d}", .{gop});
                const logical = op >= Op.group_non_uniform_logical_and;
                const cmb = combineOf(op);
                const xs = try g.get(in[5]);
                const c = try g.newComps(@intCast(xs.len));
                for (g.slice(c), xs) |*o, x| {
                    const xv = if (logical) g.sel(.u32, x, u(1), u(0)) else x;
                    const v = try g.groupArith(cmb, gop, cluster, xv);
                    o.* = if (logical) g.icmp(.u32, .ne, v, u(0)) else v;
                }
                g.setVal(id, c);
            },
        }
    }

    // ── Arithmetic ──

    fn arith(g: *Gen, op: u16, in: []const u32) Error!void {
        if (in.len < 4) return g.unsupported("spirv: op {d}", .{op});
        const rt = in[1];
        const id = in[2];
        const n = g.comps(rt);
        switch (op) {
            Op.dot => {
                const a = try g.get(in[3]);
                const b = try g.get(in[4]);
                try g.define(id, &.{g.dotOf(a, b)});
                return;
            },
            Op.any, Op.all => {
                const a = try g.get(in[3]);
                var acc: Arg = a[0];
                for (a[1..]) |x| acc = if (op == Op.any) g.por(acc, x) else g.pand(acc, x);
                try g.define(id, &.{acc});
                return;
            },
            Op.vector_times_scalar, Op.matrix_times_scalar => {
                const a = try g.get(in[3]);
                const s = (try g.get(in[4]))[0];
                const c = try g.newComps(n);
                for (g.slice(c), a) |*o, x| o.* = g.fop(.fmul, x, s);
                g.setVal(id, c);
                return;
            },
            Op.matrix_times_vector => {
                const m = try g.get(in[3]);
                const v = try g.get(in[4]);
                const rows = n;
                const c = try g.newComps(rows);
                for (0..rows) |ri| {
                    var acc: Arg = g.fop(.fmul, m[ri], v[0]);
                    for (1..v.len) |ci| acc = g.fop(.fadd, acc, g.fop(.fmul, m[ci * rows + ri], v[ci]));
                    g.slice(c)[ri] = acc;
                }
                g.setVal(id, c);
                return;
            },
            Op.vector_times_matrix => {
                const v = try g.get(in[3]);
                const m = try g.get(in[4]);
                const rows = v.len;
                const c = try g.newComps(n);
                for (0..n) |ci| g.slice(c)[ci] = g.dotOf(v, m[ci * rows ..][0..rows]);
                g.setVal(id, c);
                return;
            },
            Op.matrix_times_matrix => {
                const a = try g.get(in[3]);
                const b = try g.get(in[4]);
                const rows = g.lenOf(g.elemOf(rt, 0));
                const cols = g.lenOf(rt);
                const inner = b.len / cols;
                const c = try g.newComps(n);
                for (0..cols) |ci| {
                    for (0..rows) |ri| {
                        var acc: Arg = g.fop(.fmul, a[ri], b[ci * inner]);
                        for (1..inner) |x| acc = g.fop(.fadd, acc, g.fop(.fmul, a[x * rows + ri], b[ci * inner + x]));
                        g.slice(c)[ci * rows + ri] = acc;
                    }
                }
                g.setVal(id, c);
                return;
            },
            Op.outer_product => {
                const a = try g.get(in[3]);
                const b = try g.get(in[4]);
                const c = try g.newComps(n);
                for (0..b.len) |ci| {
                    for (0..a.len) |ri| g.slice(c)[ci * a.len + ri] = g.fop(.fmul, a[ri], b[ci]);
                }
                g.setVal(id, c);
                return;
            },
            else => {},
        }
        // component-wise
        const a = try g.get(in[3]);
        const b: []Arg = if (in.len > 4) try g.get(in[4]) else &.{};
        const c = try g.newComps(n);
        const ot = g.typeOfValue(in[3]);
        const src_ty: kir.Ty = if (ot) |t| try g.scalarTy(t) else .u32;
        const dst_ty = try g.scalarTy(rt);
        for (0..n) |j| {
            const x = a[if (a.len == 1) 0 else j];
            const y: Arg = if (b.len == 0) no else b[if (b.len == 1) 0 else j];
            g.slice(c)[j] = try g.scalarOp(op, x, y, src_ty, dst_ty);
        }
        g.setVal(id, c);
    }

    fn dotOf(g: *Gen, a: []const Arg, b: []const Arg) Arg {
        var acc: Arg = g.fop(.fmul, a[0], b[0]);
        for (1..a.len) |j| acc = g.fop(.fadd, acc, g.fop(.fmul, a[j], b[j]));
        return acc;
    }

    fn scalarOp(g: *Gen, op: u16, x: Arg, y: Arg, src: kir.Ty, dst: kir.Ty) Error!Arg {
        return switch (op) {
            Op.i_add => g.iop(.iadd, .u32, x, y),
            Op.i_sub => g.iop(.isub, .u32, x, y),
            Op.i_mul => g.iop(.imul, .u32, x, y),
            Op.u_div => g.udiv(x, y)[0],
            Op.u_mod => g.udiv(x, y)[1],
            Op.s_div => g.sdiv(x, y)[0],
            Op.s_rem => g.sdiv(x, y)[1],
            Op.s_mod => blk: {
                const rem = g.sdiv(x, y)[1];
                const fix = g.pand(g.icmp(.i32, .ne, rem, u(0)), g.icmp(.i32, .lt, g.iop(.xor, .i32, rem, y), u(0)));
                break :blk g.sel(.i32, fix, g.iop(.iadd, .i32, rem, y), rem);
            },
            Op.s_negate => if (x == .imm) u(0 -% x.imm) else g.op1(.ineg, .i32, x),
            Op.f_negate => g.fop1(.fneg, x),
            Op.f_add => g.fop(.fadd, x, y),
            Op.f_sub => g.fop(.fsub, x, y),
            Op.f_mul => g.fop(.fmul, x, y),
            Op.f_div => g.fop(.fdiv, x, y),
            Op.f_rem, Op.f_mod => blk: {
                const q = g.fop(.fdiv, x, y);
                const t = g.fop1(if (op == Op.f_rem) .ftrunc else .ffloor, q);
                break :blk g.fop(.fsub, x, g.fop(.fmul, y, t));
            },
            Op.shift_left_logical => g.iop(.shl, .u32, x, y),
            Op.shift_right_logical => g.iop(.shr, .u32, x, y),
            Op.shift_right_arithmetic => g.iop(.shr, .i32, x, y),
            Op.bitwise_and => g.iop(.@"and", .u32, x, y),
            Op.bitwise_or => g.iop(.@"or", .u32, x, y),
            Op.bitwise_xor => g.iop(.xor, .u32, x, y),
            Op.not => if (x == .imm) u(~x.imm) else g.op1(.not, .u32, x),
            Op.i_equal => g.icmp(.u32, .eq, x, y),
            Op.i_not_equal => g.icmp(.u32, .ne, x, y),
            Op.u_greater_than => g.icmp(.u32, .gt, x, y),
            Op.s_greater_than => g.icmp(.i32, .gt, x, y),
            Op.u_greater_than_equal => g.icmp(.u32, .ge, x, y),
            Op.s_greater_than_equal => g.icmp(.i32, .ge, x, y),
            Op.u_less_than => g.icmp(.u32, .lt, x, y),
            Op.s_less_than => g.icmp(.i32, .lt, x, y),
            Op.u_less_than_equal => g.icmp(.u32, .le, x, y),
            Op.s_less_than_equal => g.icmp(.i32, .le, x, y),
            // (KIR's fcmp is ordered, but ne, which is true on NaN)
            Op.f_ord_equal => g.fcmp(.eq, x, y),
            Op.f_ord_less_than => g.fcmp(.lt, x, y),
            Op.f_ord_greater_than => g.fcmp(.gt, x, y),
            Op.f_ord_less_than_equal => g.fcmp(.le, x, y),
            Op.f_ord_greater_than_equal => g.fcmp(.ge, x, y),
            Op.f_ord_not_equal => g.por(g.fcmp(.lt, x, y), g.fcmp(.gt, x, y)),
            Op.f_unord_not_equal => g.fcmp(.ne, x, y),
            Op.f_unord_equal => g.pnot(g.por(g.fcmp(.lt, x, y), g.fcmp(.gt, x, y))),
            Op.f_unord_less_than => g.pnot(g.fcmp(.ge, x, y)),
            Op.f_unord_greater_than => g.pnot(g.fcmp(.le, x, y)),
            Op.f_unord_less_than_equal => g.pnot(g.fcmp(.gt, x, y)),
            Op.f_unord_greater_than_equal => g.pnot(g.fcmp(.lt, x, y)),
            Op.is_nan => g.fcmp(.ne, x, x),
            Op.is_inf => g.fcmp(.eq, g.fop1(.fabs, x), f(std.math.inf(f32))),
            Op.logical_and => g.pand(x, y),
            Op.logical_or => g.por(x, y),
            Op.logical_not => g.pnot(x),
            Op.logical_not_equal => g.pxor(x, y),
            Op.logical_equal => g.pnot(g.pxor(x, y)),
            Op.convert_f_to_u => if (x == .imm) u(cvtImm(x.imm, false)) else r(g.k.cvt(.f32, .u32, .rz, x)),
            Op.convert_f_to_s => if (x == .imm) u(cvtImm(x.imm, true)) else r(g.k.cvt(.f32, .i32, .rz, x)),
            Op.convert_s_to_f => if (x == .imm) f(@floatFromInt(@as(i32, @bitCast(x.imm)))) else r(g.k.cvt(.i32, .f32, .rne, x)),
            Op.convert_u_to_f => if (x == .imm) f(@floatFromInt(x.imm)) else r(g.k.cvt(.u32, .f32, .rne, x)),
            Op.u_convert, Op.s_convert => x,
            Op.f_convert => x,
            Op.bitcast => g.cast(x, src, dst),
            Op.quantize_to_f16 => blk: {
                const h = r(g.k.cvt(.f32, .f16, .rne, r(g.reg(x, .f32))));
                break :blk r(g.k.cvt(.f16, .f32, .rne, h));
            },
            Op.bit_count => g.popcount(x),
            Op.bit_reverse => g.bitReverse(x),
            else => return g.unsupported("spirv: op {d}", .{op}),
        };
    }

    fn popcount(g: *Gen, x0: Arg) Arg {
        const x = r(g.reg(x0, .u32));
        const a = g.iop(.isub, .u32, x, g.iop(.@"and", .u32, g.iop(.shr, .u32, x, u(1)), u(0x5555_5555)));
        const b = g.iop(.iadd, .u32, g.iop(.@"and", .u32, a, u(0x3333_3333)), g.iop(.@"and", .u32, g.iop(.shr, .u32, a, u(2)), u(0x3333_3333)));
        const c = g.iop(.@"and", .u32, g.iop(.iadd, .u32, b, g.iop(.shr, .u32, b, u(4))), u(0x0f0f_0f0f));
        return g.iop(.shr, .u32, g.iop(.imul, .u32, c, u(0x0101_0101)), u(24));
    }

    fn bitReverse(g: *Gen, x0: Arg) Arg {
        var x = r(g.reg(x0, .u32));
        const masks = [_]u32{ 0x5555_5555, 0x3333_3333, 0x0f0f_0f0f, 0x00ff_00ff };
        var sh: u32 = 1;
        for (masks) |m| {
            x = g.iop(.@"or", .u32, g.iop(.@"and", .u32, g.iop(.shr, .u32, x, u(sh)), u(m)), g.iop(.shl, .u32, g.iop(.@"and", .u32, x, u(m)), u(sh)));
            sh *= 2;
        }
        return g.iop(.@"or", .u32, g.iop(.shr, .u32, x, u(16)), g.iop(.shl, .u32, x, u(16)));
    }

    /// The highest set bit's index (-1 for 0).
    fn findMsb(g: *Gen, x0: Arg) Arg {
        var x = r(g.reg(x0, .u32));
        var n: Arg = u(0);
        var s: u32 = 16;
        while (s > 0) : (s /= 2) {
            const hi = g.iop(.shr, .u32, x, u(s));
            const has = g.icmp(.u32, .ne, hi, u(0));
            x = g.sel(.u32, has, hi, x);
            n = g.iop(.iadd, .u32, n, g.sel(.u32, has, u(s), u(0)));
        }
        return g.sel(.u32, g.icmp(.u32, .eq, x, u(0)), u(0xffff_ffff), n);
    }

    fn bitfield(g: *Gen, in: []const u32, op: u16) Error!void {
        const xs = try g.get(in[3]);
        const c = try g.newComps(@intCast(xs.len));
        switch (op) {
            Op.bit_field_insert => {
                const ins = try g.get(in[4]);
                const off = (try g.get(in[5]))[0];
                const cnt = (try g.get(in[6]))[0];
                const full = g.icmp(.u32, .ge, cnt, u(32));
                const base_mask = g.sel(.u32, full, u(0xffff_ffff), g.iop(.isub, .u32, g.iop(.shl, .u32, u(1), cnt), u(1)));
                const mask = g.iop(.shl, .u32, base_mask, off);
                for (g.slice(c), xs, ins) |*o, x, y| {
                    o.* = g.iop(.@"or", .u32, g.iop(.@"and", .u32, x, g.iop(.xor, .u32, mask, u(0xffff_ffff))), g.iop(.@"and", .u32, g.iop(.shl, .u32, y, off), mask));
                }
            },
            else => {
                const off = (try g.get(in[4]))[0];
                const cnt = (try g.get(in[5]))[0];
                const ty: kir.Ty = if (op == Op.bit_field_s_extract) .i32 else .u32;
                for (g.slice(c), xs) |*o, x| {
                    const v = r(g.k.op3(.bfe, ty, r(g.reg(x, ty)), off, cnt));
                    o.* = g.sel(ty, g.icmp(.u32, .eq, cnt, u(0)), u(0), v);
                }
            },
        }
        g.setVal(in[2], c);
    }

    fn glsl(g: *Gen, in: []const u32) Error!void {
        const rt = in[1];
        const id = in[2];
        const e = in[4];
        const n = g.comps(rt);
        const ops = in[5..];
        var av: [3][]Arg = .{ &.{}, &.{}, &.{} };
        for (ops, 0..) |o, j| {
            if (j >= 3) break;
            av[j] = try g.get(o);
        }
        const ty = try g.scalarTy(rt);
        switch (e) {
            GLSL.length => {
                try g.define(id, &.{g.fsqrt(g.dotOf(av[0], av[0]))});
                return;
            },
            GLSL.distance => {
                var d: [4]Arg = undefined;
                for (av[0], av[1], 0..) |x, y, j| d[j] = g.fop(.fsub, x, y);
                const dd = d[0..av[0].len];
                try g.define(id, &.{g.fsqrt(g.dotOf(dd, dd))});
                return;
            },
            GLSL.normalize => {
                const inv = g.fop1(.frsq, g.dotOf(av[0], av[0]));
                const c = try g.newComps(n);
                for (g.slice(c), av[0]) |*o, x| o.* = g.fop(.fmul, x, inv);
                g.setVal(id, c);
                return;
            },
            GLSL.cross => {
                const a = av[0];
                const b = av[1];
                try g.define(id, &.{
                    g.fop(.fsub, g.fop(.fmul, a[1], b[2]), g.fop(.fmul, a[2], b[1])),
                    g.fop(.fsub, g.fop(.fmul, a[2], b[0]), g.fop(.fmul, a[0], b[2])),
                    g.fop(.fsub, g.fop(.fmul, a[0], b[1]), g.fop(.fmul, a[1], b[0])),
                });
                return;
            },
            GLSL.reflect => {
                // i - 2 * dot(n, i) * n
                const d2 = g.fop(.fmul, f(2), g.dotOf(av[1], av[0]));
                const c = try g.newComps(n);
                for (g.slice(c), av[0], av[1]) |*o, x, nn| o.* = g.fop(.fsub, x, g.fop(.fmul, d2, nn));
                g.setVal(id, c);
                return;
            },
            GLSL.face_forward => {
                const neg = g.fcmp(.lt, g.dotOf(av[2], av[1]), f(0));
                const c = try g.newComps(n);
                for (g.slice(c), av[0]) |*o, x| o.* = g.sel(.f32, neg, x, g.fop1(.fneg, x));
                g.setVal(id, c);
                return;
            },
            GLSL.pack_half2x16 => {
                const lo = g.half(av[0][0]);
                const hi = g.half(av[0][1]);
                try g.define(id, &.{g.iop(.@"or", .u32, lo, g.iop(.shl, .u32, hi, u(16)))});
                return;
            },
            GLSL.unpack_half2x16 => {
                const x = av[0][0];
                try g.define(id, &.{ g.unhalf(g.iop(.@"and", .u32, x, u(0xffff))), g.unhalf(g.iop(.shr, .u32, x, u(16))) });
                return;
            },
            GLSL.pack_unorm4x8, GLSL.pack_snorm4x8, GLSL.pack_unorm2x16, GLSL.pack_snorm2x16 => {
                const signed = e == GLSL.pack_snorm4x8 or e == GLSL.pack_snorm2x16;
                const bits: u32 = if (e == GLSL.pack_unorm4x8 or e == GLSL.pack_snorm4x8) 8 else 16;
                const scale: f32 = if (signed) @floatFromInt((@as(u32, 1) << @intCast(bits - 1)) - 1) else @floatFromInt((@as(u32, 1) << @intCast(bits)) - 1);
                var acc: Arg = u(0);
                for (av[0], 0..) |x, j0| {
                    const j: u32 = @intCast(j0);
                    const cl = g.fop(.fmin, g.fop(.fmax, x, f(if (signed) -1 else 0)), f(1));
                    const q = r(g.k.cvt(.f32, .i32, .rz, g.fop1(.frne, g.fop(.fmul, cl, f(scale)))));
                    const m = g.iop(.@"and", .u32, q, u((@as(u32, 1) << @intCast(bits)) - 1));
                    acc = g.iop(.@"or", .u32, acc, g.iop(.shl, .u32, m, u(j * bits)));
                }
                try g.define(id, &.{acc});
                return;
            },
            GLSL.unpack_unorm4x8, GLSL.unpack_snorm4x8, GLSL.unpack_unorm2x16, GLSL.unpack_snorm2x16 => {
                const signed = e == GLSL.unpack_snorm4x8 or e == GLSL.unpack_snorm2x16;
                const bits: u32 = if (e == GLSL.unpack_unorm4x8 or e == GLSL.unpack_snorm4x8) 8 else 16;
                const x = r(g.reg(av[0][0], .u32));
                const c = try g.newComps(n);
                for (g.slice(c), 0..) |*o, j0| {
                    const sh: u32 = @as(u32, @intCast(j0)) * bits;
                    if (signed) {
                        const v = r(g.k.op3(.bfe, .i32, x, u(sh), u(bits)));
                        const fl = r(g.k.cvt(.i32, .f32, .rne, v));
                        const scale: f32 = @floatFromInt((@as(u32, 1) << @intCast(bits - 1)) - 1);
                        o.* = g.fop(.fmax, g.fop(.fdiv, fl, f(scale)), f(-1));
                    } else {
                        const v = r(g.k.op3(.bfe, .u32, x, u(sh), u(bits)));
                        const fl = r(g.k.cvt(.u32, .f32, .rne, v));
                        o.* = g.fop(.fdiv, fl, f(@floatFromInt((@as(u32, 1) << @intCast(bits)) - 1)));
                    }
                }
                g.setVal(id, c);
                return;
            },
            else => {},
        }
        const c = try g.newComps(n);
        for (0..n) |j| {
            const x = if (av[0].len > 0) av[0][if (av[0].len == 1) 0 else j] else no;
            const y = if (av[1].len > 0) av[1][if (av[1].len == 1) 0 else j] else no;
            const z = if (av[2].len > 0) av[2][if (av[2].len == 1) 0 else j] else no;
            g.slice(c)[j] = try g.glslScalar(e, ty, x, y, z);
        }
        g.setVal(id, c);
    }

    fn half(g: *Gen, x: Arg) Arg {
        const h = r(g.k.cvt(.f32, .f16, .rne, r(g.reg(x, .f32))));
        return g.iop(.@"and", .u32, r(g.k.mov(.u32, h)), u(0xffff));
    }
    fn unhalf(g: *Gen, bits: Arg) Arg {
        const h = r(g.k.mov(.f16, r(g.reg(bits, .u32))));
        return r(g.k.cvt(.f16, .f32, .rne, h));
    }
    fn fsqrt(g: *Gen, x: Arg) Arg {
        return g.fop1(.fsqrt, x);
    }
    fn exp(g: *Gen, x: Arg) Arg {
        return g.fop1(.fexp2, g.fop(.fmul, x, f(std.math.log2e)));
    }

    /// atan(x) for any x: a polynomial on [0, 1] and the reflection about 1.
    fn atan(g: *Gen, x: Arg) Arg {
        const ax = g.fop1(.fabs, x);
        const big = g.fcmp(.gt, ax, f(1));
        const t = g.sel(.f32, big, g.fop(.fdiv, f(1), ax), ax);
        const t2 = g.fop(.fmul, t, t);
        // minimax on [0,1]: |error| < 1e-5
        var p: Arg = f(-0.0117212);
        for ([_]f32{ 0.05265332, -0.11643287, 0.19354346, -0.33262347, 0.99997726 }) |cf| p = g.fop(.fadd, g.fop(.fmul, p, t2), f(cf));
        const a = g.fop(.fmul, p, t);
        const res = g.sel(.f32, big, g.fop(.fsub, f(std.math.pi / 2.0), a), a);
        const neg = g.fcmp(.lt, x, f(0));
        return g.sel(.f32, neg, g.fop1(.fneg, res), res);
    }

    fn glslScalar(g: *Gen, e: u32, ty: kir.Ty, x: Arg, y: Arg, z: Arg) Error!Arg {
        _ = ty;
        return switch (e) {
            GLSL.round, GLSL.round_even => g.fop1(.frne, x),
            GLSL.trunc => g.fop1(.ftrunc, x),
            GLSL.floor => g.fop1(.ffloor, x),
            GLSL.ceil => g.fop1(.fceil, x),
            GLSL.fract => g.fop(.fsub, x, g.fop1(.ffloor, x)),
            GLSL.fabs => g.fop1(.fabs, x),
            GLSL.sabs => if (x == .imm) u(@abs(@as(i32, @bitCast(x.imm)))) else r(g.k.op1(.iabs, .i32, x)),
            GLSL.fsign => g.sel(.f32, g.fcmp(.gt, x, f(0)), f(1), g.sel(.f32, g.fcmp(.lt, x, f(0)), f(-1), f(0))),
            GLSL.ssign => g.iop(.imax, .i32, g.iop(.imin, .i32, x, u(1)), u(0xffff_ffff)),
            GLSL.radians => g.fop(.fmul, x, f(std.math.pi / 180.0)),
            GLSL.degrees => g.fop(.fmul, x, f(180.0 / std.math.pi)),
            GLSL.sin => g.fop1(.fsin, x),
            GLSL.cos => g.fop1(.fcos, x),
            GLSL.tan => g.fop(.fdiv, g.fop1(.fsin, x), g.fop1(.fcos, x)),
            GLSL.atan => g.atan(x),
            GLSL.atan2 => blk: {
                // atan(y/x), into the right quadrant (y = x here, x = y)
                const yy = x;
                const xx = y;
                const a = g.atan(g.fop(.fdiv, yy, xx));
                const xneg = g.fcmp(.lt, xx, f(0));
                const yneg = g.fcmp(.lt, yy, f(0));
                const adj = g.sel(.f32, yneg, f(-std.math.pi), f(std.math.pi));
                break :blk g.sel(.f32, xneg, g.fop(.fadd, a, adj), a);
            },
            GLSL.asin => blk: {
                // atan(x / sqrt(1 - x*x))
                const s = g.fsqrt(g.fop(.fsub, f(1), g.fop(.fmul, x, x)));
                break :blk g.atanOf2(x, s);
            },
            GLSL.acos => blk: {
                const s = g.fsqrt(g.fop(.fsub, f(1), g.fop(.fmul, x, x)));
                break :blk g.atanOf2(s, x);
            },
            GLSL.sinh, GLSL.cosh, GLSL.tanh => blk: {
                const ep = g.exp(x);
                const em = g.exp(g.fop1(.fneg, x));
                break :blk switch (e) {
                    GLSL.sinh => g.fop(.fmul, g.fop(.fsub, ep, em), f(0.5)),
                    GLSL.cosh => g.fop(.fmul, g.fop(.fadd, ep, em), f(0.5)),
                    else => g.fop(.fdiv, g.fop(.fsub, ep, em), g.fop(.fadd, ep, em)),
                };
            },
            GLSL.pow => g.fop1(.fexp2, g.fop(.fmul, y, g.fop1(.flog2, x))),
            GLSL.exp => g.exp(x),
            GLSL.log => g.fop(.fmul, g.fop1(.flog2, x), f(std.math.ln2)),
            GLSL.exp2 => g.fop1(.fexp2, x),
            GLSL.log2 => g.fop1(.flog2, x),
            GLSL.sqrt => g.fsqrt(x),
            GLSL.inverse_sqrt => g.fop1(.frsq, x),
            GLSL.fmin, GLSL.nmin => g.fop(.fmin, x, y),
            GLSL.fmax, GLSL.nmax => g.fop(.fmax, x, y),
            GLSL.umin => g.iop(.imin, .u32, x, y),
            GLSL.smin => g.iop(.imin, .i32, x, y),
            GLSL.umax => g.iop(.imax, .u32, x, y),
            GLSL.smax => g.iop(.imax, .i32, x, y),
            GLSL.fclamp, GLSL.nclamp => g.fop(.fmin, g.fop(.fmax, x, y), z),
            GLSL.uclamp => g.iop(.imin, .u32, g.iop(.imax, .u32, x, y), z),
            GLSL.sclamp => g.iop(.imin, .i32, g.iop(.imax, .i32, x, y), z),
            GLSL.fmix => g.fop(.fadd, x, g.fop(.fmul, g.fop(.fsub, y, x), z)),
            GLSL.step => g.sel(.f32, g.fcmp(.lt, y, x), f(0), f(1)),
            GLSL.smooth_step => blk: {
                const t0 = g.fop(.fdiv, g.fop(.fsub, z, x), g.fop(.fsub, y, x));
                const t = g.fop(.fmin, g.fop(.fmax, t0, f(0)), f(1));
                break :blk g.fop(.fmul, g.fop(.fmul, t, t), g.fop(.fsub, f(3), g.fop(.fmul, f(2), t)));
            },
            GLSL.fma => g.op3(.fmad, .f32, x, y, z),
            GLSL.ldexp => blk: {
                // x * 2^e, the power built in two halves (e in -252..254)
                const ec = g.iop(.imax, .i32, g.iop(.imin, .i32, y, u(254)), u(@bitCast(@as(i32, -252))));
                const h1 = g.iop(.shr, .i32, ec, u(1));
                const h2 = g.iop(.isub, .i32, ec, h1);
                const p1 = g.cast(g.iop(.shl, .u32, g.iop(.iadd, .i32, h1, u(127)), u(23)), .u32, .f32);
                const p2 = g.cast(g.iop(.shl, .u32, g.iop(.iadd, .i32, h2, u(127)), u(23)), .u32, .f32);
                break :blk g.fop(.fmul, g.fop(.fmul, x, p1), p2);
            },
            GLSL.find_ilsb => blk: {
                const xx = r(g.reg(x, .u32));
                const low = g.iop(.@"and", .u32, xx, g.op1(.ineg, .i32, xx));
                break :blk g.findMsb(low);
            },
            GLSL.find_umsb => g.findMsb(x),
            GLSL.find_smsb => blk: {
                // the highest bit that differs from the sign
                const xx = r(g.reg(x, .i32));
                const flipped = g.sel(.u32, g.icmp(.i32, .lt, xx, u(0)), g.op1(.not, .u32, xx), xx);
                break :blk g.findMsb(flipped);
            },
            else => return g.unsupported("spirv: GLSL.std.450 instruction {d}", .{e}),
        };
    }

    /// atan2(y, x) for x >= 0 cases of asin/acos (x may be 0).
    fn atanOf2(g: *Gen, y: Arg, x: Arg) Arg {
        const a = g.atan(g.fop(.fdiv, y, x));
        const xneg = g.fcmp(.lt, x, f(0));
        const yneg = g.fcmp(.lt, y, f(0));
        const adj = g.sel(.f32, yneg, f(-std.math.pi), f(std.math.pi));
        const res = g.sel(.f32, xneg, g.fop(.fadd, a, adj), a);
        // x == 0: +-pi/2
        const xz = g.fcmp(.eq, x, f(0));
        return g.sel(.f32, xz, g.sel(.f32, yneg, f(-std.math.pi / 2.0), f(std.math.pi / 2.0)), res);
    }
};

fn cvtImm(bits: u32, signed: bool) u32 {
    const x: f32 = @bitCast(bits);
    if (std.math.isNan(x)) return 0;
    const t = @trunc(x);
    if (signed) {
        if (t <= -2147483648.0) return 0x8000_0000;
        if (t >= 2147483647.0) return 0x7fff_ffff;
        return @bitCast(@as(i32, @intFromFloat(t)));
    }
    if (t <= 0) return 0;
    if (t >= 4294967295.0) return 0xffff_ffff;
    return @intFromFloat(t);
}

/// A literal string's text (up to its NUL).
fn litStr(words: []const u32) []const u8 {
    const bytes = std.mem.sliceAsBytes(words);
    const end = std.mem.indexOfScalar(u8, bytes, 0) orelse bytes.len;
    return bytes[0..end];
}

/// Whether an opcode has a result (type, id) pair, for the module scan.
fn hasResult(op: u16) bool {
    return switch (op) {
        Op.store, Op.copy_memory, Op.control_barrier, Op.memory_barrier, Op.atomic_store, Op.loop_merge, Op.selection_merge, Op.branch, Op.branch_conditional, Op.@"switch", Op.kill, Op.@"return", Op.return_value, Op.@"unreachable", Op.terminate_invocation, Op.image_write, Op.demote_to_helper_invocation => false,
        else => true,
    };
}

// ── The API ─────────────────────────────────────────────────────────────────

/// A Gen over `words` (the module, 4-byte aligned), with the caller's scratch.
pub fn init(words: []const u32, s: *Scratch, opts: Options) Gen {
    return .{ .w = words, .s = s, .opts = opts };
}

/// The words of SPIR-V bytes (their length a multiple of 4, aligned).
pub fn wordsOf(bytes: []align(4) const u8) []const u32 {
    return std.mem.bytesAsSlice(u32, bytes[0 .. bytes.len & ~@as(usize, 3)]);
}

test {
    std.testing.refAllDecls(@This());
}
