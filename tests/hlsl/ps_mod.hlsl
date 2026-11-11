// Uniforms

uniform float2 _u_period : register(c0);
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


float mod_emu(float x, float y)
{
    return x - y * floor(x / y);
}
float2 mod_emu(float2 x, float2 y)
{
    return x - y * floor(x / y);
}
float2 mod_emu(float2 x, float y)
{
    return x - y * floor(x / y);
}


void gl_main()
{
float2 _p = mod_emu((_v_color.xy * 7.3), _u_period);
float _q = mod_emu(_v_color.z * 5.0, 0.7);
float2 _r = mod_emu(_v_color.zw * 3.1, 0.45);
float _e = step(0.5, _v_color.w);
float _s = smoothstep(0.2, 0.8, _v_color.x);
(gl_Color[0] = float4(frac(_p.x * 1.7), ((_p.y + _q) * 0.5), ((_r.x + _e) * 0.5), ((_s + _r.y) * 0.5)));
(gl_Color[0] += float4(fmod(_v_color.x * 3.3, 0.6), floor(_v_color.y * 2.0) * 0.1, ceil(_v_color.z) * 0.1, round(_v_color.w * 3.0) * 0.1) * 0.25);
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
