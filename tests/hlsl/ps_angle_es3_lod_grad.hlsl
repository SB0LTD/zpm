// ANGLE's own HLSL for a WebGL program (es3_lod_grad), captured from Chromium's ANGLE
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

uniform float _u_lod : register(c0);
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
    SamplerMetadata samplerMetadata[1] : packoffset(c4);
};

float4 gl_texture2DLod(uint samplerIndex, float2 t, float lod)
{
    return textures2D[samplerIndex].SampleLevel(samplers2D[samplerIndex], float2(t.x, t.y), lod);
}

float4 gl_texture2DGrad(uint samplerIndex, float2 t, float2 ddx, float2 ddy)
{
    return textures2D[samplerIndex].SampleGrad(samplers2D[samplerIndex], float2(t.x, t.y), ddx, ddy);
}

float4 gl_texture2DOffset(uint samplerIndex, float2 t, int2 offset)
{
    return textures2D[samplerIndex].Sample(samplers2D[samplerIndex], float2(t.x, t.y), offset);
}

float4 gl_texture2DProj(uint samplerIndex, float3 t)
{
    return textures2D[samplerIndex].Sample(samplers2D[samplerIndex], float2((t.x / t.z), (t.y / t.z)));
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

float4 _a_3006 = gl_texture2DLod(_u_tex, _v_uv, _u_lod);
float4 _b_3007 = gl_texture2DGrad(_u_tex, _v_uv.yx, ddx(_v_uv), ddy(_v_uv));
float4 _c_3008 = gl_texture2DProj(_u_tex, vec3_ctor(_v_uv, 2.0));
float4 _d_3009 = gl_texture2DOffset(_u_tex, _v_uv, int2(1, -1));
(out_o = (((((_a_3006 + _b_3007) + _c_3008) + _d_3009) * 0.25) + vec4_ctor(fwidth(_v_uv.x))));
return generateOutput();
}

// INITIAL HLSL END



