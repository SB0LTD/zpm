// ANGLE's own HLSL for a WebGL program (es3_3d_uint), captured from Chromium's ANGLE
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
float3 vec3_ctor(float2 x0, float x1)
{
    return float3(x0, x1);
}
float4 vec4_ctor_uint4(uint4 x0)
{
    return float4(x0);
}
int2 ivec2_ctor(float2 x0)
{
    return int2(x0);
}
// Uniforms

static const uint _u_vol = 0;
static const uint textureIndexOffset3D = 0;
static const uint samplerIndexOffset3D = 0;
uniform Texture3D<float4> textures3D[1] : register(t0);
uniform SamplerState samplers3D[1] : register(s0);
static const uint _u_bits = 1;
static const uint textureIndexOffset2D_uint4_ = 1;
static const uint samplerIndexOffset2D_uint4_ = 1;
uniform Texture2D<uint4> textures2D_uint4_[1] : register(t1);
uniform SamplerState samplers2D_uint4_[1] : register(s1);
#ifdef ANGLE_ENABLE_LOOP_FLATTEN
#define LOOP [loop]
#define FLATTEN [flatten]
#else
#define LOOP
#define FLATTEN
#endif
// Varyings
static  float2 _v_uv = {0, 0};

static float4 out_o = {0, 0, 0, 0};

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
    SamplerMetadata samplerMetadata[2] : packoffset(c4);
};

float4 gl_texture3D(uint samplerIndex, float3 t)
{
    const uint textureIndex = samplerIndex - textureIndexOffset3D;
    const uint samplerArrayIndex = samplerIndex - samplerIndexOffset3D;
    return textures3D[textureIndex].Sample(samplers3D[samplerArrayIndex], float3(t.x, t.y, t.z));
}

uint4 gl_texture2D_uint4_Fetch(uint samplerIndex, int2 t, int mip)
{
    const uint textureIndex = samplerIndex - textureIndexOffset2D_uint4_;
    const uint samplerArrayIndex = samplerIndex - samplerIndexOffset2D_uint4_;
    int baseLevel = 0;
    return textures2D_uint4_[textureIndex].Load(int3(t.x, t.y, mip));
}

struct PS_OUTPUT
{
    float4 out_o : SV_Target0;
};

PS_OUTPUT generateOutput()
{
    PS_OUTPUT output;
    output.out_o = out_o;
    return output;
}


PS_OUTPUT main(PS_INPUT input){
    _v_uv = input.v0;

float4 _a_3006 = gl_texture3D(_u_vol, vec3_ctor(_v_uv, 0.5));
uint4 _b_3007 = gl_texture2D_uint4_Fetch(_u_bits, ivec2_ctor((_v_uv * 4.0)), 0);
(out_o = ((_a_3006 * 0.5) + (vec4_ctor_uint4(_b_3007) / 255.0)));
return generateOutput();
}

// INITIAL HLSL END



