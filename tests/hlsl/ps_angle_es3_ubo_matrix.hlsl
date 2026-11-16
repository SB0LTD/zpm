// ANGLE's own HLSL for a WebGL program (es3_ubo_matrix), captured from Chromium's ANGLE
// (Direct3D 11 renderer) with WEBGL_debug_shaders; DynamicHLSL's stubs
// filled as ANGLE's link does.
struct PS_INPUT
{
    float4 dx_Position : SV_Position;
    float4 gl_Position : TEXCOORD1;
    float4 v0 : TEXCOORD0;
};

// INITIAL HLSL BEGIN

#pragma warning( disable: 3081 3556 3557 3571 )
float2x2 mat2_ctor(float x0, float x1, float x2, float x3)
{
    return float2x2(x0, x1, x2, x3);
}
float4 vec4_ctor(float2 x0, float x1, float x2)
{
    return float4(x0, x1, x2);
}
// Uniforms

uniform float2x2 _u_m2 : register(c0);
uniform float3x3 _u_m3 : register(c2);
#ifdef ANGLE_ENABLE_LOOP_FLATTEN
#define LOOP [loop]
#define FLATTEN [flatten]
#else
#define LOOP
#define FLATTEN
#endif
// Varyings
static  float4 _v_c = {0, 0, 0, 0};

static float4 out_o = {0, 0, 0, 0};

cbuffer DriverConstants : register(b1)
{
    uint dx_Misc : packoffset(c2.w);
};

float2x2 inverse_emu(in float2x2 m)
{
    float2x2 cof = { m[1][1], -m[0][1], -m[1][0], m[0][0] };
    return cof / determinant(transpose(m));
}


struct PS_OUTPUT
{
    float4 out_o : SV_Target0;
};

PS_OUTPUT generateOutput()
{
    PS_OUTPUT output;
    output.out_o = out_o;
    return output;
}


PS_OUTPUT main(PS_INPUT input){
    _v_c = input.v0;

float2x2 _a_3006 = mat2_ctor(_v_c.x, _v_c.y, _v_c.z, _v_c.w);
float2 _v_3007 = mul(transpose(transpose(mul(transpose(_u_m2), transpose(_a_3006)))), _v_c.xy);
float3 _w_3008 = mul(_v_c.xyz, transpose(_u_m3));
(out_o = vec4_ctor((_v_3007 * 0.5), (determinant(transpose(_a_3006)) + _w_3008.x), ((inverse_emu(_a_3006)[0][0] * 0.00999999978) + transpose(_u_m3)[1].z)));
return generateOutput();
}

// INITIAL HLSL END



