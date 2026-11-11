// Uniforms

uniform float4 _u_k : register(c0);
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


void split_float4_float2_float2(in float4 _v, out float2 _lo, out float2 _hi)
{
(_lo = _v.xy);
(_hi = _v.zw);
}
void accumulate_float3_float(inout float3 _acc, in float _w)
{
(_acc += (_acc * _w));
(_acc = min(_acc, 2.0));
}
float scale(float x) { return x * 2.0; }
float2 scale(float2 x) { return x * 3.0; }
int scale(int x) { return x * 4; }


void gl_main()
{
float2 _lo = {0, 0};
float2 _hi = {0, 0};
split_float4_float2_float2(_v_color, _lo, _hi);
float3 _acc = float3(_lo, _hi.x);
accumulate_float3_float(_acc, _u_k.x);
accumulate_float3_float(_acc, _u_k.y);
(gl_Color[0] = float4(_acc * 0.25, scale(_hi.y) * 0.1 + scale(_lo).x * 0.01 + float(scale(2)) * 0.01));
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
