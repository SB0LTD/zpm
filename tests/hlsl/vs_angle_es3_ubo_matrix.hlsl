// ANGLE's own HLSL for a WebGL program (es3_ubo_matrix), captured from Chromium's ANGLE
// (Direct3D 11 renderer) with WEBGL_debug_shaders; DynamicHLSL's stubs
// filled as ANGLE's link does.
// INITIAL HLSL BEGIN

#pragma warning( disable: 3081 3556 3557 3571 )
// Uniform Blocks

cbuffer Frame : register(b2)
{
    row_major float4x4 _u_vp;
    float4 _u_tint;
    float _u_scale;
};

#ifdef ANGLE_ENABLE_LOOP_FLATTEN
#define LOOP [loop]
#define FLATTEN [flatten]
#else
#define LOOP
#define FLATTEN
#endif
// Attributes
static float4 _a_pos = {0, 0, 0, 0};

static float4 gl_Position = float4(0, 0, 0, 0);

// Varyings
static  float4 _v_c = {0, 0, 0, 0};

cbuffer DriverConstants : register(b1)
{
    float2 dx_ViewScale  : packoffset(c1);
    float clipControlOrigin : packoffset(c1.z);
    float clipControlZeroToOne : packoffset(c1.w);
};

struct VS_INPUT
{
    float4 _a_pos : TEXCOORD0;
};

void initAttributes(VS_INPUT input)
{
    _a_pos = input._a_pos;
}


struct VS_OUTPUT
{
    float4 dx_Position : SV_Position;
    float4 gl_Position : TEXCOORD1;
    float4 v0 : TEXCOORD0;
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
    output.v0 = _v_c;
    return output;
}


VS_OUTPUT main(VS_INPUT input){
    initAttributes(input);

(gl_Position = float4(0.0, 0.0, 0.0, 0.0));
(_v_c = (_u_tint * _u_scale));
(gl_Position = mul(transpose(_u_vp), _a_pos));
return generateOutput(input);
}

// INITIAL HLSL END



