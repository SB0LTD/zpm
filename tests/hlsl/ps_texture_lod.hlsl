// Uniforms

static const uint _s_tex = 0;
uniform Texture2D<float4> textures2D[1] : register(t0);
uniform SamplerState samplers2D[1] : register(s0);
uniform float _u_lod : register(c0);
uniform float _u_bias : register(c1);
#ifdef ANGLE_ENABLE_LOOP_FLATTEN
#define LOOP [loop]
#define FLATTEN [flatten]
#else
#define LOOP
#define FLATTEN
#endif

#define ATOMIC_COUNTER_ARRAY_STRIDE 4


// Varyings
static  float4 _v_color = {0, 0, 0, 0};

static float4 gl_Color[1] = {float4(0, 0, 0, 0)};

cbuffer DriverConstants : register(b1)
{
    float4 dx_ViewCoords : packoffset(c1);
    float2 dx_FragCoordOffset : packoffset(c3);
    float3 dx_DepthFront : packoffset(c2);
    float2 dx_ViewScale : packoffset(c3.z);
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
float4 gl_texture2DBias(uint samplerIndex, float2 t, float bias)
{
    return textures2D[samplerIndex].SampleBias(samplers2D[samplerIndex], float2(t.x, t.y), bias);
}
float4 gl_texture2DGrad(uint samplerIndex, float2 t, float2 ddx, float2 ddy)
{
    return textures2D[samplerIndex].SampleGrad(samplers2D[samplerIndex], float2(t.x, t.y), ddx, ddy);
}
float4 gl_texture2DProj(uint samplerIndex, float3 t)
{
    return textures2D[samplerIndex].Sample(samplers2D[samplerIndex], float2(t.x / t.z, t.y / t.z));
}
float4 gl_texture2DLodOffset(uint samplerIndex, float2 t, float lod, int2 offset)
{
    return textures2D[samplerIndex].SampleLevel(samplers2D[samplerIndex], float2(t.x, t.y), lod, offset);
}


void gl_main()
{
float4 _a = gl_texture2DLod(_s_tex, _v_color.xy, _u_lod);
float4 _b = gl_texture2DBias(_s_tex, _v_color.yx, _u_bias);
float4 _c = gl_texture2DGrad(_s_tex, _v_color.zw, float2(0.01, 0.0), float2(0.0, 0.02));
float4 _d = gl_texture2DProj(_s_tex, float3(_v_color.xy, 2.0));
float4 _e = gl_texture2DLodOffset(_s_tex, _v_color.wz, 0.0, int2(1, -1));
(gl_Color[0] = ((((_a + _b) + _c) + _d) + _e) * 0.2);
}

struct PS_INPUT
{
    float4 dx_Position : SV_Position;
    float4 gl_Position : TEXCOORD1;
    float4 v0 : TEXCOORD0;
};

struct PS_OUTPUT
{
    float4 gl_Color0 : SV_Target0;
};

PS_OUTPUT generateOutput()
{
    PS_OUTPUT output;
    output.gl_Color0 = gl_Color[0];
    return output;
}

PS_OUTPUT main(PS_INPUT input){
    _v_color = input.v0;

    gl_main();

    return generateOutput();
}
