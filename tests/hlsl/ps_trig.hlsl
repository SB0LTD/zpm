// Uniforms

uniform float _u_time : register(c0);
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


float atan_emu(float y, float x)
{
    if(x == 0 && y == 0) x = 1;
    return atan2(y, x);
}


void gl_main()
{
float _a = atan_emu((_v_color.y - 0.5), (_v_color.x - 0.5));
float _b = acos(clamp(((_v_color.x * 2.0) - 1.0), -1.0, 1.0));
float _c = asin(clamp(((_v_color.y * 2.0) - 1.0), -1.0, 1.0));
float _d = atan((_v_color.z * 4.0) - 2.0);
float _e = (sin(_u_time + _v_color.x) * cos(_v_color.y * 3.0)) + tan(_v_color.z * 0.5);
float _f = exp(_v_color.w) * 0.2 + log(_v_color.x + 1.0) + exp2(_v_color.y) * 0.1 + log2(_v_color.z + 1.0);
float _g = sqrt(_v_color.x) + rsqrt(_v_color.y + 1.0) + pow(_v_color.z + 0.1, 2.2) + sinh(_v_color.w) * 0.1 + cosh(_v_color.x) * 0.1 + tanh(_v_color.y);
(gl_Color[0] = float4((_a * 0.15) + 0.5, (_b * 0.3), ((_c * 0.3) + 0.5), frac(_d + _e + _f + _g)));
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
