// ANGLE's own HLSL for a WebGL program (es3_switch_flat), captured from Chromium's ANGLE
// (Direct3D 11 renderer) with WEBGL_debug_shaders; DynamicHLSL's stubs
// filled as ANGLE's link does.
// INITIAL HLSL BEGIN

#pragma warning( disable: 3081 3556 3557 3571 )
float4 vec4_ctor(float2 x0, float x1, float x2)
{
    return float4(x0, x1, x2);
}
// Uniforms

uniform int _u_mode : register(c0);
#ifdef ANGLE_ENABLE_LOOP_FLATTEN
#define LOOP [loop]
#define FLATTEN [flatten]
#else
#define LOOP
#define FLATTEN
#endif
// Attributes
static float2 _a_pos = {0, 0};

static float4 gl_Position = float4(0, 0, 0, 0);
static int gl_VertexID;

// Varyings
static nointerpolation int _v_id = {0};
static  float3 _v_c = {0, 0, 0};

cbuffer DriverConstants : register(b1)
{
    float2 dx_ViewScale  : packoffset(c1);
    float clipControlOrigin : packoffset(c1.z);
    float clipControlZeroToOne : packoffset(c1.w);
    uint dx_VertexID : packoffset(c2.x);
};

#define GL_USES_VERTEX_ID
struct VS_INPUT
{
    float2 _a_pos : TEXCOORD0;
};

void initAttributes(VS_INPUT input)
{
    _a_pos = input._a_pos;
}


struct VS_OUTPUT
{
    float4 dx_Position : SV_Position;
    float4 gl_Position : TEXCOORD2;
    nointerpolation int v0 : TEXCOORD0;
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
    output.v0 = _v_id;
    output.v1 = _v_c;
    return output;
}


VS_OUTPUT main(VS_INPUT input){
    initAttributes(input);

(gl_Position = float4(0.0, 0.0, 0.0, 0.0));
(_v_id = (gl_VertexID + _u_mode));
float3 _c_3006 = {0.25, 0.25, 0.25};
switch (_u_mode) {
case (1):
(_c_3006 = _c_3006.zyx);
break;
case (2):
(_c_3006 *= 2.0);
break;
default:
(_c_3006 += 0.100000001);
break;
}
(_v_c = _c_3006);
(gl_Position = vec4_ctor(_a_pos, 0.0, 1.0));
return generateOutput(input);
}

// INITIAL HLSL END



