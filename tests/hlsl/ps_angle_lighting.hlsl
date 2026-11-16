// ANGLE's own HLSL for a WebGL program (lighting), captured from Chromium's ANGLE
// (Direct3D 11 renderer) with WEBGL_debug_shaders; DynamicHLSL's stubs
// filled as ANGLE's link does.
struct PS_INPUT
{
    float4 dx_Position : SV_Position;
    float4 gl_Position : TEXCOORD2;
    float3 v0 : TEXCOORD0;
    float3 v1 : TEXCOORD1;
};

// INITIAL HLSL BEGIN

#pragma warning( disable: 3081 3556 3557 3571 )
float4 vec4_ctor(float3 x0, float x1)
{
    return float4(x0, x1);
}
// Uniforms

uniform float3 _u_light : register(c0);
uniform float3 _u_eye : register(c1);
uniform float _u_shin : register(c2);
#ifdef ANGLE_ENABLE_LOOP_FLATTEN
#define LOOP [loop]
#define FLATTEN [flatten]
#else
#define LOOP
#define FLATTEN
#endif
// Varyings
static  float3 _v_n = {0, 0, 0};
static  float3 _v_w = {0, 0, 0};

static float4 gl_Color[1] =
{
    float4(0, 0, 0, 0)
};

cbuffer DriverConstants : register(b1)
{
    uint dx_Misc : packoffset(c2.w);
};

#define GL_USES_FRAG_COLOR
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
    _v_n = input.v0;
    _v_w = input.v1;

float3 _n_3007 = normalize(_v_n);
float3 _l_3008 = normalize((_u_light - _v_w));
float3 _v_3009 = normalize((_u_eye - _v_w));
float _d_3010 = max(dot(_n_3007, _l_3008), 0.0);
float _s_3011 = pow(max(dot(reflect((-_l_3008), _n_3007), _v_3009), 0.0), _u_shin);
(gl_Color[0] = vec4_ctor(((float3(0.100000001, 0.100000001, 0.100000001) + (_d_3010 * float3(0.800000012, 0.600000024, 0.400000006))) + _s_3011), 1.0));
return generateOutput();
}

// INITIAL HLSL END



