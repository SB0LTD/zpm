// ANGLE's own HLSL for a WebGL program (math_builtins), captured from Chromium's ANGLE
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
float4 vec4_ctor(float x0, float x1, float x2, float x3)
{
    return float4(x0, x1, x2, x3);
}
// Uniforms

uniform float _u_t : register(c0);
#ifdef ANGLE_ENABLE_LOOP_FLATTEN
#define LOOP [loop]
#define FLATTEN [flatten]
#else
#define LOOP
#define FLATTEN
#endif
// Varyings
static  float2 _v_uv = {0, 0};

static float4 gl_Color[1] =
{
    float4(0, 0, 0, 0)
};

cbuffer DriverConstants : register(b1)
{
    uint dx_Misc : packoffset(c2.w);
};

#define GL_USES_FRAG_COLOR
float atan_emu(float y, float x)
{
    if(x == 0 && y == 0) x = 1;
    return atan2(y, x);
}


float mod_emu(float x, float y)
{
    return x - y * floor(x / y);
}


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
    _v_uv = input.v0;

float _a_3004 = atan_emu((_v_uv.y - 0.5), (_v_uv.x - 0.5));
float _b_3005 = mod_emu((_v_uv.x * 7.30000019), 0.699999988);
float2 _f_3006 = frac((_v_uv * 5.0));
float _s_3007 = (smoothstep(0.200000003, 0.800000012, _v_uv.x) * step(0.5, _v_uv.y));
float _e_3008 = ((((exp(_v_uv.x) + log((_v_uv.y + 1.0))) + pow((_v_uv.x + 0.100000001), 2.20000005)) + sqrt(_v_uv.y)) + rsqrt((_v_uv.x + 1.0)));
(gl_Color[0] = vec4_ctor(((sin((_a_3004 + _u_t)) * 0.5) + 0.5), _b_3005, (_f_3006.x * _s_3007), frac(((_e_3008 + acos(((_v_uv.x * 2.0) - 1.0))) + asin(((_v_uv.y * 2.0) - 1.0))))));
return generateOutput();
}

// INITIAL HLSL END



