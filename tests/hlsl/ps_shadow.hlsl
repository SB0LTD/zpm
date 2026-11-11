// Uniforms

static const uint _s_shadow = 0;
uniform Texture2D textures2D_comparison[1] : register(t0);
uniform SamplerComparisonState samplers2D_comparison[1] : register(s0);
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


float gl_texture2DShadow(uint samplerIndex, float3 t)
{
    return textures2D_comparison[samplerIndex].SampleCmp(samplers2D_comparison[samplerIndex], float2(t.x, t.y), t.z);
}
float gl_texture2DShadowLod0(uint samplerIndex, float3 t)
{
    return textures2D_comparison[samplerIndex].SampleCmpLevelZero(samplers2D_comparison[samplerIndex], float2(t.x, t.y), t.z);
}


void gl_main()
{
float _s = gl_texture2DShadow(_s_shadow, _v_color.xyz);
float _t = gl_texture2DShadowLod0(_s_shadow, _v_color.yxz);
(gl_Color[0] = float4(_s, _t, 0.0, 1.0));
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
