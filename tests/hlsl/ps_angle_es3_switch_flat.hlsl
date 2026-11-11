// ANGLE's own HLSL for a WebGL program (es3_switch_flat), captured from Chromium's ANGLE
// (Direct3D 11 renderer) with WEBGL_debug_shaders; DynamicHLSL's stubs
// filled as ANGLE's link does.
struct PS_INPUT
{
    float4 dx_Position : SV_Position;
    float4 gl_Position : TEXCOORD2;
    nointerpolation int v0 : TEXCOORD0;
    float3 v1 : TEXCOORD1;
};

// INITIAL HLSL BEGIN

#pragma warning( disable: 3081 3556 3557 3571 )
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
static nointerpolation int _v_id = {0};
static  float3 _v_c = {0, 0, 0};

static float4 out_o = {0, 0, 0, 0};

cbuffer DriverConstants : register(b1)
{
    uint dx_Misc : packoffset(c2.w);
};

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
    _v_id = input.v0;
    _v_c = input.v1;

float3 _c_3005 = _v_c;
switch ((_v_id & 3)) {
case (0):
(_c_3005.x = 1.0);
break;
case (1):
(_c_3005.y = 1.0);
break;
default:
(_c_3005.z = 0.5);
break;
}
(out_o = vec4_ctor(_c_3005, 1.0));
return generateOutput();
}

// INITIAL HLSL END



