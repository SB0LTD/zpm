// Uniforms

cbuffer UniformBlock0 : register(b2)
{
    float4 _u_scale : packoffset(c0);
    float3 _u_bias : packoffset(c1);
    float _u_factor : packoffset(c1.w);
    float4x4 _u_xform : packoffset(c2);
    int2 _u_counts : packoffset(c6);
};
cbuffer Material : register(b3)
{
    float4 _u_diffuse;
    float2 _u_rough;
    float _u_metal;
    float3 _u_emissive;
    float4 _u_unused;
};
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




void gl_main()
{
float4 _c = ((_v_color * _u_scale) + float4(_u_bias, _u_factor));
(_c = mul(transpose(_u_xform), _c));
(_c.xy += (float2(_u_counts) * 0.01));
(gl_Color[0] = (_c * _u_diffuse) + float4(_u_emissive, _u_metal) * _u_rough.x);
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
