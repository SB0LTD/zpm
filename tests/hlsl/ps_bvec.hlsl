// Uniforms

uniform float4 _u_edge : register(c0);
uniform bool _u_flip : register(c1);
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


bool4 bvec4_ctor(bool x0)
{
    return bool4(x0, x0, x0, x0);
}


void gl_main()
{
bool4 _lt = (_v_color < _u_edge);
bool4 _ne = (_v_color != float4(0.5, 0.5, 0.5, 0.5));
bool _any = any(_lt);
bool _all = all(_ne);
float4 _sel = (_lt ? _v_color : (1.0 - _v_color));
FLATTEN if (_u_flip)
{
(_sel = _sel.wzyx);
}
bool4 _b = (_lt && (!_ne)) || bvec4_ctor(_all);
(gl_Color[0] = (_sel * 0.5) + (float4(_b) * 0.25) + (_any ? 0.1 : 0.0));
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
