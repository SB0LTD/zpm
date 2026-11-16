// ANGLE's own HLSL for a WebGL program (points), captured from Chromium's ANGLE
// (Direct3D 11 renderer) with WEBGL_debug_shaders; DynamicHLSL's stubs
// filled as ANGLE's link does.
// INITIAL HLSL BEGIN

#pragma warning( disable: 3081 3556 3557 3571 )
float4 vec4_ctor(float2 x0, float x1, float x2)
{
    return float4(x0, x1, x2);
}
// Uniforms

uniform float _u_size : register(c0);
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
static float gl_PointSize = float(1);

// Varyings

cbuffer DriverConstants : register(b1)
{
    float2 dx_ViewScale  : packoffset(c1);
    float clipControlOrigin : packoffset(c1.z);
    float clipControlZeroToOne : packoffset(c1.w);
};

#define GL_USES_POINT_SIZE
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
    float4 gl_Position : TEXCOORD0;
    float2 gl_PointCoord : TEXCOORD2;
    float gl_PointSize : PSIZE;
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
    output.gl_PointCoord = float2(0.5, 0.5);
    output.gl_PointSize = gl_PointSize;

    return output;
}


VS_OUTPUT main(VS_INPUT input){
    initAttributes(input);

(gl_Position = float4(0.0, 0.0, 0.0, 0.0));
(gl_PointSize = _u_size);
(gl_Position = vec4_ctor(_a_pos, 0.0, 1.0));
return generateOutput(input);
}

// INITIAL HLSL END



