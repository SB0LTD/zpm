// ANGLE's own HLSL for a WebGL program (functions_out), captured from Chromium's ANGLE
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
float3 vec3_ctor(float2 x0, float x1)
{
    return float3(x0, x1);
}
float4 vec4_ctor(float2 x0, float2 x1)
{
    return float4(x0, x1);
}
float4 vec4_ctor(float3 x0, float x1)
{
    return float4(x0, x1);
}
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
};

#define GL_USES_FRAG_COLOR
void f_split_float4(in float4 _v_3003, inout float2 _lo_3004, inout float2 _hi_3005)
{
(_lo_3004 = _v_3003.xy);
(_hi_3005 = _v_3003.zw);
}
void f_acc(inout float3 _a_3007, in float _w_3008)
{
(_a_3007 += (_a_3007 * _w_3008));
(_a_3007 = min(_a_3007, 2.0));
}
float f_classify(in float _x_3010)
{
if ((_x_3010 < 0.25))
{
return 0.100000001;
}
if ((_x_3010 < 0.5))
{
return 0.400000006;
}
return 0.899999976;
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

float2 _lo_3012 = {0, 0};
float2 _hi_3013 = {0, 0};
f_split_float4(vec4_ctor(_v_uv, _v_uv.yx), _lo_3012, _hi_3013);
float3 _a_3014 = vec3_ctor(_lo_3012, _hi_3013.x);
f_acc(_a_3014, 0.5);
(gl_Color[0] = vec4_ctor((_a_3014 * 0.300000012), f_classify(_v_uv.x)));
return generateOutput();
}

// INITIAL HLSL END



