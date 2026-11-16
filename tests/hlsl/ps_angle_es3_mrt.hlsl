// ANGLE's own HLSL for a WebGL program (es3_mrt), captured from Chromium's ANGLE
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
float4 vec4_ctor(float2 x0, float x1, float x2)
{
    return float4(x0, x1, x2);
}
// Uniforms

uniform float4 _u_a : register(c0);
#ifdef ANGLE_ENABLE_LOOP_FLATTEN
#define LOOP [loop]
#define FLATTEN [flatten]
#else
#define LOOP
#define FLATTEN
#endif
// Varyings
static  float2 _v_uv = {0, 0};

static float4 out_o0 = {0, 0, 0, 0};
static float4 out_o1 = {0, 0, 0, 0};

cbuffer DriverConstants : register(b1)
{
    uint dx_Misc : packoffset(c2.w);
};

struct PS_OUTPUT
{
    float4 out_o0 : SV_Target0;
    float4 out_o1 : SV_Target1;
};

PS_OUTPUT generateOutput()
{
    PS_OUTPUT output;
    output.out_o0 = out_o0;
    output.out_o1 = out_o1;
    return output;
}


PS_OUTPUT main(PS_INPUT input){
    _v_uv = input.v0;

(out_o0 = vec4_ctor(_v_uv, 0.0, 1.0));
(out_o1 = (vec4_ctor(_v_uv.yx, 1.0, 1.0) * _u_a));
return generateOutput();
}

// INITIAL HLSL END



