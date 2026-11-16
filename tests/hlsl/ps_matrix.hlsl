// Uniforms

uniform float2x2 _u_m2 : register(c0);
uniform float3x3 _u_m3 : register(c2);
uniform float4x4 _u_m4 : register(c5);
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


float2x2 mat2_ctor(float x0, float x1, float x2, float x3)
{
    return float2x2(x0, x1, x2, x3);
}


void gl_main()
{
float2x2 _a = mat2_ctor(_v_color.x, _v_color.y, _v_color.z, _v_color.w);
float2x2 _b = transpose(mul(transpose(_u_m2), transpose(_a)));
float2 _v = mul(transpose(_b), _v_color.xy);
float3 _w = mul(_v_color.xyz, transpose(_u_m3));
float _det = determinant(transpose(_a));
float3x3 _c = (_u_m3 * 0.5);
(_c[1] += _w);
float4 _x = mul(transpose(_u_m4), _v_color);
(gl_Color[0] = float4((_v * 0.5), (_det + _c[1][2]), ((_x.w + _c[2].x) * 0.25)));
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
