// Uniforms

uniform int _u_i : register(c0);
uniform uint _u_u : register(c1);
uniform bool _u_b : register(c2);
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
int _a = int(_v_color.x * 10.0);
uint _b = uint(_v_color.y * 10.0);
bool _c = bool(_v_color.z);
bool _d = bool(_u_i);
float _e = float(_c) + float(_d) * 0.5 + float(_u_b) * 0.25;
int _f = int(_c) + int(_u_u) + int(-3.7);
uint _g = uint(_a) + _b + uint(_u_b);
float3 _h = float3(int3(_v_color.xyz * 3.0)) * 0.3;
(gl_Color[0] = float4(_e * 0.5, float(_f) * 0.1, float(_g) * 0.05, (_h.x + _h.y + _h.z) * 0.2));
(gl_Color[0].x = asfloat(asuint(gl_Color[0].x)));
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
