// ANGLE's own HLSL for a WebGL program (es3_ints_fetch), captured from Chromium's ANGLE
// (Direct3D 11 renderer) with WEBGL_debug_shaders; DynamicHLSL's stubs
// filled as ANGLE's link does.
struct PS_INPUT
{
    float4 dx_Position : SV_Position;
    float4 gl_Position : TEXCOORD1;
    float2 v0 : TEXCOORD0;
};

// INITIAL HLSL BEGIN

#pragma warning( disable: 3081 3556 3557 3571 )
float float_ctor_int(int x0)
{
    return float(x0);
}
float float_ctor_uint(uint x0)
{
    return float(x0);
}
float4 vec4_ctor(float x0, float x1, float x2, float x3)
{
    return float4(x0, x1, x2, x3);
}
int int_ctor(float x0)
{
    return int(x0);
}
int2 ivec2_ctor_int_int(int x0, int x1)
{
    return int2(x0, x1);
}
uint uint_ctor(float x0)
{
    return uint(x0);
}
// Uniforms

uniform int _u_shift : register(c0);
uniform uint _u_mask : register(c1);
static const uint _u_tex = 0;
uniform Texture2D<float4> textures2D[1] : register(t0);
uniform SamplerState samplers2D[1] : register(s0);
#ifdef ANGLE_ENABLE_LOOP_FLATTEN
#define LOOP [loop]
#define FLATTEN [flatten]
#else
#define LOOP
#define FLATTEN
#endif
// Varyings
static  float2 _v_uv = {0, 0};

static float4 out_o_color = {0, 0, 0, 0};

cbuffer DriverConstants : register(b1)
{
    uint dx_Misc : packoffset(c2.w);
    struct SamplerMetadata
    {
        int baseLevel;
        int wrapModes;
        int2 padding;
        int4 intBorderColor;
    };
    SamplerMetadata samplerMetadata[1] : packoffset(c4);
};

int2 gl_texture2DSize(uint samplerIndex, int lod)
{
    int baseLevel = 0;
    uint width; uint height; uint numberOfLevels;
    textures2D[samplerIndex].GetDimensions(baseLevel, width, height, numberOfLevels);
    width = max(width >> lod, 1);
    height = max(height >> lod, 1);
    return int2(width, height);
}

float4 gl_texture2DFetch(uint samplerIndex, int2 t, int mip)
{
    return textures2D[samplerIndex].Load(int3(t.x, t.y, mip));
}

struct PS_OUTPUT
{
    float4 out_o_color : SV_Target0;
};

PS_OUTPUT generateOutput()
{
    PS_OUTPUT output;
    output.out_o_color = out_o_color;
    return output;
}


PS_OUTPUT main(PS_INPUT input){
    _v_uv = input.v0;

int _x_3007 = int_ctor((_v_uv.x * 100.0));
uint _u_3008 = uint_ctor((_v_uv.y * 200.0));
int _a_3009 = (((_x_3007 << _u_shift) ^ (_x_3007 >> 1)) | 7);
uint _c_3010 = (((_u_3008 / 7) + (_u_3008 % 3)) & _u_mask);
int2 _sz_3011 = gl_texture2DSize(_u_tex, 0);
float4 _t_3012 = gl_texture2DFetch(_u_tex, ivec2_ctor_int_int((_x_3007 % _sz_3011.x), 1), 0);
(out_o_color = ((vec4_ctor((float_ctor_int((_a_3009 & 255)) / 255.0), (float_ctor_uint(_c_3010) / 64.0), (float_ctor_int(_sz_3011.y) * 0.00999999978), 1.0) * 0.5) + (_t_3012 * 0.5)));
return generateOutput();
}

// INITIAL HLSL END



