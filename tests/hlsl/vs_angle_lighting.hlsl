// ANGLE's own HLSL for a WebGL program (lighting), captured from Chromium's ANGLE
// (Direct3D 11 renderer) with WEBGL_debug_shaders; DynamicHLSL's stubs
// filled as ANGLE's link does.
// INITIAL HLSL BEGIN

#pragma warning( disable: 3081 3556 3557 3571 )
float4 vec4_ctor(float3 x0, float x1)
{
    return float4(x0, x1);
}
// Uniforms

uniform float4x4 _u_model : register(c0);
uniform float4x4 _u_vp : register(c4);
uniform float3x3 _u_nm : register(c8);
#ifdef ANGLE_ENABLE_LOOP_FLATTEN
#define LOOP [loop]
#define FLATTEN [flatten]
#else
#define LOOP
#define FLATTEN
#endif
// Attributes
static float3 _a_pos = {0, 0, 0};
static float3 _a_n = {0, 0, 0};

static float4 gl_Position = float4(0, 0, 0, 0);

// Varyings
static  float3 _v_n = {0, 0, 0};
static  float3 _v_w = {0, 0, 0};

cbuffer DriverConstants : register(b1)
{
    float2 dx_ViewScale  : packoffset(c1);
    float clipControlOrigin : packoffset(c1.z);
    float clipControlZeroToOne : packoffset(c1.w);
};

struct VS_INPUT
{
    float3 _a_pos : TEXCOORD0;
    float3 _a_n : TEXCOORD1;
};

void initAttributes(VS_INPUT input)
{
    _a_pos = input._a_pos;
    _a_n = input._a_n;
}


struct VS_OUTPUT
{
    float4 dx_Position : SV_Position;
    float4 gl_Position : TEXCOORD2;
    float3 v0 : TEXCOORD0;
    float3 v1 : TEXCOORD1;
};
VS_OUTPUT generateOutput(VS_INPUT input)
{
    VS_OUTPUT output;
    output.gl_Position = gl_Position;
    output.dx_Position.x = gl_Position.x;
    output.dx_Position.y = clipControlOrigin * gl_Position.y;
    if (clipControlZeroToOne)
    {
        output.dx_Position.z = gl_Position.z;
    } else {
        output.dx_Position.z = (gl_Position.z + gl_Position.w) * 0.5;
    }
    output.dx_Position.w = gl_Position.w;
    output.v0 = _v_n;
    output.v1 = _v_w;
    return output;
}


VS_OUTPUT main(VS_INPUT input){
    initAttributes(input);

(gl_Position = float4(0.0, 0.0, 0.0, 0.0));
float4 _w_3009 = mul(transpose(_u_model), vec4_ctor(_a_pos, 1.0));
(_v_w = _w_3009.xyz);
(_v_n = normalize(mul(transpose(_u_nm), _a_n)));
(gl_Position = mul(transpose(_u_vp), _w_3009));
return generateOutput(input);
}

// INITIAL HLSL END



