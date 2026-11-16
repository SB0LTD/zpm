// ANGLE's own HLSL for a WebGL program (fragcoord_facing), captured from Chromium's ANGLE
// (Direct3D 11 renderer) with WEBGL_debug_shaders; DynamicHLSL's stubs
// filled as ANGLE's link does.
struct PS_INPUT
{
    float4 dx_Position : SV_Position;
    float4 gl_Position : TEXCOORD1;
    float4 gl_FragCoord : TEXCOORD2;
    float2 v0 : TEXCOORD0;
};

// INITIAL HLSL BEGIN

#pragma warning( disable: 3081 3556 3557 3571 )
float4 vec4_ctor(float2 x0, float x1, float x2)
{
    return float4(x0, x1, x2);
}
// Uniforms

uniform float2 _u_res : register(c0);
#ifdef ANGLE_ENABLE_LOOP_FLATTEN
#define LOOP [loop]
#define FLATTEN [flatten]
#else
#define LOOP
#define FLATTEN
#endif
// Varyings

static float4 gl_Color[1] =
{
    float4(0, 0, 0, 0)
};
static float4 gl_FragCoord = float4(0, 0, 0, 0);
static bool gl_FrontFacing = false;

cbuffer DriverConstants : register(b1)
{
    float4 dx_ViewCoords : packoffset(c1);
    float2 dx_FragCoordOffset : packoffset(c3);
    float3 dx_DepthFront : packoffset(c2);
    float2 dx_ViewScale : packoffset(c3.z);
    uint dx_Misc : packoffset(c2.w);
};

#define GL_USES_FRAG_COLOR
#define GL_USES_FRAG_COORD
#define GL_USES_FRONT_FACING
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


PS_OUTPUT main(PS_INPUT input, bool isFrontFace : SV_IsFrontFace){
    float rhw = 1.0 / input.gl_FragCoord.w;
    gl_FragCoord.x = input.dx_Position.x - dx_FragCoordOffset.x;
    gl_FragCoord.y = input.dx_Position.y - dx_FragCoordOffset.y;
    gl_FragCoord.z = input.dx_Position.z;
    gl_FragCoord.w = rhw;
    gl_FrontFacing = isFrontFace;

float2 _uv_3004 = (gl_FragCoord.xy / _u_res);
float4 sbbd = {0, 0, 0, 0};
if (gl_FrontFacing)
{
(sbbd = vec4_ctor(_uv_3004, gl_FragCoord.z, 1.0));
}
else
{
(sbbd = vec4_ctor((1.0 - _uv_3004), 0.0, 1.0));
}
(gl_Color[0] = sbbd);
return generateOutput();
}

// INITIAL HLSL END



