// ANGLE's own HLSL for a WebGL program (es3_array_shadow), captured from Chromium's ANGLE
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
float4 vec4_ctor(float x0)
{
    return float4(x0, x0, x0, x0);
}
// Uniforms

static const uint _u_arr = 0;
static const uint textureIndexOffset2DArray = 0;
static const uint samplerIndexOffset2DArray = 0;
uniform Texture2DArray<float4> textures2DArray[1] : register(t0);
uniform SamplerState samplers2DArray[1] : register(s0);
static const uint _u_sh = 1;
static const uint textureIndexOffset2D_comparison = 1;
static const uint samplerIndexOffset2D_comparison = 1;
uniform Texture2D textures2D_comparison[1] : register(t1);
uniform SamplerComparisonState samplers2D_comparison[1] : register(s1);
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

float4 gl_texture2DArray(uint samplerIndex, float3 t)
{
    const uint textureIndex = samplerIndex - textureIndexOffset2DArray;
    const uint samplerArrayIndex = samplerIndex - samplerIndexOffset2DArray;
    return textures2DArray[textureIndex].Sample(samplers2DArray[samplerArrayIndex], float3(t.x, t.y, t.z));
}

float gl_texture2D_comparison(uint samplerIndex, float3 t)
{
    const uint textureIndex = samplerIndex - textureIndexOffset2D_comparison;
    const uint samplerArrayIndex = samplerIndex - samplerIndexOffset2D_comparison;
    return textures2D_comparison[textureIndex].SampleCmp(samplers2D_comparison[samplerArrayIndex], float2(t.x, t.y), t.z);
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

float4 _a_3006 = gl_texture2DArray(_u_arr, vec3_ctor(_v_uv, 1.0));
float _s_3007 = gl_texture2D_comparison(_u_sh, vec3_ctor(_v_uv, 0.5));
(out_o = ((_a_3006 * 0.5) + (vec4_ctor(_s_3007) * 0.5)));
return generateOutput();
}

// INITIAL HLSL END



