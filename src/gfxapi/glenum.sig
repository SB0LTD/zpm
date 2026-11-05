//! @zpm/gfxapi glenum — OpenGL ES 3.0's enum values (Khronos' gl2.h,
//! gl3.h and gl2ext.h), named as GL names them without the GL_ prefix.

pub const NO_ERROR: u32 = 0;
pub const NONE: u32 = 0;
pub const FALSE: u8 = 0;
pub const TRUE: u8 = 1;

// errors
pub const INVALID_ENUM: u32 = 0x0500;
pub const INVALID_VALUE: u32 = 0x0501;
pub const INVALID_OPERATION: u32 = 0x0502;
pub const OUT_OF_MEMORY: u32 = 0x0505;
pub const INVALID_FRAMEBUFFER_OPERATION: u32 = 0x0506;

// robustness (EXT_robustness, KHR_robustness)
pub const GUILTY_CONTEXT_RESET: u32 = 0x8253;
pub const INNOCENT_CONTEXT_RESET: u32 = 0x8254;
pub const UNKNOWN_CONTEXT_RESET: u32 = 0x8255;

// clear
pub const DEPTH_BUFFER_BIT: u32 = 0x0100;
pub const STENCIL_BUFFER_BIT: u32 = 0x0400;
pub const COLOR_BUFFER_BIT: u32 = 0x4000;
pub const COLOR: u32 = 0x1800;
pub const DEPTH: u32 = 0x1801;
pub const STENCIL: u32 = 0x1802;
pub const DEPTH_STENCIL: u32 = 0x84F9;

// capabilities (Enable, Disable, IsEnabled)
pub const CULL_FACE: u32 = 0x0B44;
pub const DEPTH_TEST: u32 = 0x0B71;
pub const STENCIL_TEST: u32 = 0x0B90;
pub const DITHER: u32 = 0x0BD0;
pub const BLEND: u32 = 0x0BE2;
pub const SCISSOR_TEST: u32 = 0x0C11;
pub const POLYGON_OFFSET_FILL: u32 = 0x8037;
pub const SAMPLE_ALPHA_TO_COVERAGE: u32 = 0x809E;
pub const SAMPLE_COVERAGE: u32 = 0x80A0;
pub const RASTERIZER_DISCARD: u32 = 0x8C89;
pub const PRIMITIVE_RESTART_FIXED_INDEX: u32 = 0x8D69;

// hints
pub const DONT_CARE: u32 = 0x1100;
pub const FASTEST: u32 = 0x1101;
pub const NICEST: u32 = 0x1102;
pub const GENERATE_MIPMAP_HINT: u32 = 0x8192;
pub const FRAGMENT_SHADER_DERIVATIVE_HINT: u32 = 0x8B8B;

// strings
pub const VENDOR: u32 = 0x1F00;
pub const RENDERER: u32 = 0x1F01;
pub const VERSION: u32 = 0x1F02;
pub const EXTENSIONS: u32 = 0x1F03;
pub const SHADING_LANGUAGE_VERSION: u32 = 0x8B8C;

// state queries
pub const LINE_WIDTH: u32 = 0x0B21;
pub const DEPTH_RANGE: u32 = 0x0B70;
pub const DEPTH_WRITEMASK: u32 = 0x0B72;
pub const DEPTH_CLEAR_VALUE: u32 = 0x0B73;
pub const STENCIL_CLEAR_VALUE: u32 = 0x0B91;
pub const STENCIL_WRITEMASK: u32 = 0x0B98;
pub const VIEWPORT: u32 = 0x0BA2;
pub const READ_BUFFER: u32 = 0x0C02;
pub const SCISSOR_BOX: u32 = 0x0C10;
pub const COLOR_CLEAR_VALUE: u32 = 0x0C22;
pub const COLOR_WRITEMASK: u32 = 0x0C23;
pub const UNPACK_ROW_LENGTH: u32 = 0x0CF2;
pub const UNPACK_SKIP_ROWS: u32 = 0x0CF3;
pub const UNPACK_SKIP_PIXELS: u32 = 0x0CF4;
pub const UNPACK_ALIGNMENT: u32 = 0x0CF5;
pub const PACK_ROW_LENGTH: u32 = 0x0D02;
pub const PACK_SKIP_ROWS: u32 = 0x0D03;
pub const PACK_SKIP_PIXELS: u32 = 0x0D04;
pub const PACK_ALIGNMENT: u32 = 0x0D05;
pub const MAX_TEXTURE_SIZE: u32 = 0x0D33;
pub const MAX_VIEWPORT_DIMS: u32 = 0x0D3A;
pub const SUBPIXEL_BITS: u32 = 0x0D50;
pub const RED_BITS: u32 = 0x0D52;
pub const GREEN_BITS: u32 = 0x0D53;
pub const BLUE_BITS: u32 = 0x0D54;
pub const ALPHA_BITS: u32 = 0x0D55;
pub const DEPTH_BITS: u32 = 0x0D56;
pub const STENCIL_BITS: u32 = 0x0D57;
pub const UNPACK_SKIP_IMAGES: u32 = 0x806D;
pub const UNPACK_IMAGE_HEIGHT: u32 = 0x806E;
pub const TEXTURE_BINDING_2D: u32 = 0x8069;
pub const SAMPLE_BUFFERS: u32 = 0x80A8;
pub const SAMPLES: u32 = 0x80A9;
pub const MAX_RENDERBUFFER_SIZE: u32 = 0x84E8;
pub const ACTIVE_TEXTURE: u32 = 0x84E0;
pub const MAX_DRAW_BUFFERS: u32 = 0x8824;
pub const DRAW_BUFFER0: u32 = 0x8825;
pub const MAX_TEXTURE_IMAGE_UNITS: u32 = 0x8872;
pub const ARRAY_BUFFER_BINDING: u32 = 0x8894;
pub const ELEMENT_ARRAY_BUFFER_BINDING: u32 = 0x8895;
pub const PIXEL_PACK_BUFFER_BINDING: u32 = 0x88ED;
pub const PIXEL_UNPACK_BUFFER_BINDING: u32 = 0x88EF;
pub const UNIFORM_BUFFER_BINDING: u32 = 0x8A28;
pub const MAX_COMBINED_TEXTURE_IMAGE_UNITS: u32 = 0x8B4D;
pub const IMPLEMENTATION_COLOR_READ_TYPE: u32 = 0x8B9A;
pub const IMPLEMENTATION_COLOR_READ_FORMAT: u32 = 0x8B9B;
pub const STENCIL_BACK_WRITEMASK: u32 = 0x8CA5;
pub const DRAW_FRAMEBUFFER_BINDING: u32 = 0x8CA6;
pub const FRAMEBUFFER_BINDING: u32 = 0x8CA6;
pub const RENDERBUFFER_BINDING: u32 = 0x8CA7;
pub const READ_FRAMEBUFFER_BINDING: u32 = 0x8CAA;
pub const MAX_COLOR_ATTACHMENTS: u32 = 0x8CDF;
pub const MAX_SAMPLES: u32 = 0x8D57;
pub const MAJOR_VERSION: u32 = 0x821B;
pub const MINOR_VERSION: u32 = 0x821C;
pub const NUM_EXTENSIONS: u32 = 0x821D;

// textures
pub const TEXTURE: u32 = 0x1702;
pub const TEXTURE_2D: u32 = 0x0DE1;
pub const TEXTURE_3D: u32 = 0x806F;
pub const TEXTURE_2D_ARRAY: u32 = 0x8C1A;
pub const TEXTURE_CUBE_MAP: u32 = 0x8513;
pub const TEXTURE_EXTERNAL_OES: u32 = 0x8D65;
pub const TEXTURE_BINDING_EXTERNAL_OES: u32 = 0x8D67;
pub const REQUIRED_TEXTURE_IMAGE_UNITS_OES: u32 = 0x8D68;
pub const TEXTURE0: u32 = 0x84C0;
pub const TEXTURE_MAG_FILTER: u32 = 0x2800;
pub const TEXTURE_MIN_FILTER: u32 = 0x2801;
pub const TEXTURE_WRAP_S: u32 = 0x2802;
pub const TEXTURE_WRAP_T: u32 = 0x2803;
pub const TEXTURE_WRAP_R: u32 = 0x8072;
pub const TEXTURE_BASE_LEVEL: u32 = 0x813C;
pub const TEXTURE_MAX_LEVEL: u32 = 0x813D;
pub const TEXTURE_IMMUTABLE_FORMAT: u32 = 0x912F;
pub const TEXTURE_IMMUTABLE_LEVELS: u32 = 0x82DF;
pub const NEAREST: u32 = 0x2600;
pub const LINEAR: u32 = 0x2601;
pub const NEAREST_MIPMAP_NEAREST: u32 = 0x2700;
pub const LINEAR_MIPMAP_NEAREST: u32 = 0x2701;
pub const NEAREST_MIPMAP_LINEAR: u32 = 0x2702;
pub const LINEAR_MIPMAP_LINEAR: u32 = 0x2703;
pub const REPEAT: u32 = 0x2901;
pub const CLAMP_TO_EDGE: u32 = 0x812F;
pub const MIRRORED_REPEAT: u32 = 0x8370;

// formats and types
pub const UNSIGNED_BYTE: u32 = 0x1401;
pub const UNSIGNED_SHORT: u32 = 0x1403;
pub const UNSIGNED_INT: u32 = 0x1405;
pub const FLOAT: u32 = 0x1406;
pub const UNSIGNED_INT_24_8: u32 = 0x84FA;
pub const DEPTH_COMPONENT: u32 = 0x1902;
pub const RED: u32 = 0x1903;
pub const ALPHA: u32 = 0x1906;
pub const RGB: u32 = 0x1907;
pub const RGBA: u32 = 0x1908;
pub const LUMINANCE: u32 = 0x1909;
pub const LUMINANCE_ALPHA: u32 = 0x190A;
pub const RG: u32 = 0x8227;
pub const RGBA_INTEGER: u32 = 0x8D99;
pub const BGRA_EXT: u32 = 0x80E1;
pub const RGBA4: u32 = 0x8056;
pub const RGB5_A1: u32 = 0x8057;
pub const RGB8: u32 = 0x8051;
pub const RGBA8: u32 = 0x8058;
pub const RGB565: u32 = 0x8D62;
pub const BGRA8_EXT: u32 = 0x93A1;
pub const DEPTH_COMPONENT16: u32 = 0x81A5;
pub const DEPTH_COMPONENT24: u32 = 0x81A6;
pub const DEPTH24_STENCIL8: u32 = 0x88F0;
pub const STENCIL_INDEX8: u32 = 0x8D48;
pub const UNSIGNED_NORMALIZED: u32 = 0x8C17;

// buffers
pub const ARRAY_BUFFER: u32 = 0x8892;
pub const ELEMENT_ARRAY_BUFFER: u32 = 0x8893;
pub const PIXEL_PACK_BUFFER: u32 = 0x88EB;
pub const PIXEL_UNPACK_BUFFER: u32 = 0x88EC;
pub const UNIFORM_BUFFER: u32 = 0x8A11;
pub const TRANSFORM_FEEDBACK_BUFFER: u32 = 0x8C8E;
pub const COPY_READ_BUFFER: u32 = 0x8F36;
pub const COPY_WRITE_BUFFER: u32 = 0x8F37;
pub const STREAM_DRAW: u32 = 0x88E0;
pub const STREAM_READ: u32 = 0x88E1;
pub const STREAM_COPY: u32 = 0x88E2;
pub const STATIC_DRAW: u32 = 0x88E4;
pub const STATIC_READ: u32 = 0x88E5;
pub const STATIC_COPY: u32 = 0x88E6;
pub const DYNAMIC_DRAW: u32 = 0x88E8;
pub const DYNAMIC_READ: u32 = 0x88E9;
pub const DYNAMIC_COPY: u32 = 0x88EA;
pub const BUFFER_SIZE: u32 = 0x8764;
pub const BUFFER_USAGE: u32 = 0x8765;
pub const BUFFER_MAPPED: u32 = 0x88BC;
pub const BUFFER_ACCESS_FLAGS: u32 = 0x911F;
pub const BUFFER_MAP_LENGTH: u32 = 0x9120;
pub const BUFFER_MAP_OFFSET: u32 = 0x9121;

// framebuffers and renderbuffers
pub const BACK: u32 = 0x0405;
pub const FRAMEBUFFER: u32 = 0x8D40;
pub const RENDERBUFFER: u32 = 0x8D41;
pub const READ_FRAMEBUFFER: u32 = 0x8CA8;
pub const DRAW_FRAMEBUFFER: u32 = 0x8CA9;
pub const COLOR_ATTACHMENT0: u32 = 0x8CE0;
pub const DEPTH_ATTACHMENT: u32 = 0x8D00;
pub const STENCIL_ATTACHMENT: u32 = 0x8D20;
pub const DEPTH_STENCIL_ATTACHMENT: u32 = 0x821A;
pub const FRAMEBUFFER_COMPLETE: u32 = 0x8CD5;
pub const FRAMEBUFFER_INCOMPLETE_ATTACHMENT: u32 = 0x8CD6;
pub const FRAMEBUFFER_INCOMPLETE_MISSING_ATTACHMENT: u32 = 0x8CD7;
pub const FRAMEBUFFER_UNSUPPORTED: u32 = 0x8CDD;
pub const FRAMEBUFFER_UNDEFINED: u32 = 0x8219;
pub const FRAMEBUFFER_DEFAULT: u32 = 0x8218;
pub const FRAMEBUFFER_ATTACHMENT_COLOR_ENCODING: u32 = 0x8210;
pub const FRAMEBUFFER_ATTACHMENT_COMPONENT_TYPE: u32 = 0x8211;
pub const FRAMEBUFFER_ATTACHMENT_RED_SIZE: u32 = 0x8212;
pub const FRAMEBUFFER_ATTACHMENT_STENCIL_SIZE: u32 = 0x8217;
pub const FRAMEBUFFER_ATTACHMENT_OBJECT_TYPE: u32 = 0x8CD0;
pub const FRAMEBUFFER_ATTACHMENT_OBJECT_NAME: u32 = 0x8CD1;
pub const FRAMEBUFFER_ATTACHMENT_TEXTURE_LEVEL: u32 = 0x8CD2;
pub const RENDERBUFFER_SAMPLES: u32 = 0x8CAB;
pub const RENDERBUFFER_WIDTH: u32 = 0x8D42;
pub const RENDERBUFFER_HEIGHT: u32 = 0x8D43;
pub const RENDERBUFFER_INTERNAL_FORMAT: u32 = 0x8D44;
pub const RENDERBUFFER_RED_SIZE: u32 = 0x8D50;
pub const RENDERBUFFER_STENCIL_SIZE: u32 = 0x8D55;
