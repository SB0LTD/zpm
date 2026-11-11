// ANGLE's own HLSL for a WebGL program (textured), captured from Chromium's ANGLE
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
// Uniforms

uniform float4 _u_color : register(c0);
static const uint _u_tex = 0;
uniform Texture2D<float4> textures2D[1] : register(t0);
uniform SamplerState samplers2D[1] : register(s0);
#define ANGLE_USES_DISCARD_REWRITING
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
    struct SamplerMetadata
    {
        int baseLevel;
        int wrapModes;
        int2 padding;
        int4 intBorderColor;
    };
    SamplerMetadata samplerMetadata[1] : packoffset(c4);
};

#define GL_USES_FRAG_COLOR
float4 gl_texture2D(uint samplerIndex, float2 t)
{
    return textures2D[samplerIndex].Sample(samplers2D[samplerIndex], float2(t.x, t.y));
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

float4 _c_3005 = gl_texture2D(_u_tex, _v_uv);
if ((_c_3005.w < 0.100000001))
{
discard;
}
(gl_Color[0] = (_c_3005 * _u_color));
return generateOutput();
}

// INITIAL HLSL END



