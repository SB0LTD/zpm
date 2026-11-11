// ANGLE's own HLSL for a WebGL program (points), captured from Chromium's ANGLE
// (Direct3D 11 renderer) with WEBGL_debug_shaders; DynamicHLSL's stubs
// filled as ANGLE's link does.
struct PS_INPUT
{
    float4 dx_Position : SV_Position;
    float4 gl_Position : TEXCOORD0;
    float2 gl_PointCoord : TEXCOORD2;
    float gl_PointSize : PSIZE;
};

// INITIAL HLSL BEGIN

#pragma warning( disable: 3081 3556 3557 3571 )
float4 vec4_ctor(float2 x0, float x1, float x2)
{
    return float4(x0, x1, x2);
}
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
static float2 gl_PointCoord = float2(0.5, 0.5);

cbuffer DriverConstants : register(b1)
{
    uint dx_Misc : packoffset(c2.w);
};

#define GL_USES_FRAG_COLOR
#define GL_USES_POINT_COORD
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
    gl_PointCoord.x = input.gl_PointCoord.x;
    gl_PointCoord.y = 1.0 - input.gl_PointCoord.y;

(gl_Color[0] = vec4_ctor(gl_PointCoord, 0.0, 1.0));
return generateOutput();
}

// INITIAL HLSL END



