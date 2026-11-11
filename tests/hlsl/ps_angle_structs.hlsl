// ANGLE's own HLSL for a WebGL program (structs), captured from Chromium's ANGLE
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
struct _Light_0
{
    float3 _pos;
    float3 _color;
    float _k;
};
#pragma pack_matrix(row_major)
struct rm__Light_0
{
    float3 _pos;
    float3 _color;
    float _k;
};
#pragma pack_matrix(column_major)
struct std__Light_0
{
    float3 _pos;
    float3 _color;
    float _k;
};
#pragma pack_matrix(row_major)
struct std_rm__Light_0
{
    float3 _pos;
    float3 _color;
    float _k;
};
#pragma pack_matrix(column_major)
struct std_fp__Light_0
{
    float3 _pos;
    float pad_0;
    float3 _color;
    float _k;
};
#pragma pack_matrix(row_major)
struct std_rm_fp__Light_0
{
    float3 _pos;
    float pad_1;
    float3 _color;
    float _k;
};
#pragma pack_matrix(column_major)
float float_ctor_int(int x0)
{
    return float(x0);
}
float3 vec3_ctor(float2 x0, float x1)
{
    return float3(x0, x1);
}
float4 vec4_ctor(float3 x0, float x1)
{
    return float4(x0, x1);
}
int int_ctor(float x0)
{
    return int(x0);
}
// Uniforms

uniform _Light_0 _u_lights[2] : register(c0);
uniform float3 _u_amb : register(c4);
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
;
float3 f_shade__Light_0(in _Light_0 _l_3006, in float3 _p_3007)
{
float3 _d_3008 = (_l_3006._pos - _p_3007);
return (_l_3006._color * (_l_3006._k / (1.0 + dot(_d_3008, _d_3008))));
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

float3 _p_3010 = vec3_ctor(_v_uv, 0.0);
float3 _c_3011 = _u_amb;
{ for(int _i_3012 = {0}; (_i_3012 < 2); (_i_3012++))
{
(_c_3011 += f_shade__Light_0(_u_lights[int_ctor(clamp(float_ctor_int(_i_3012), 0.0, 1.0))], _p_3010));
}
}
(gl_Color[0] = vec4_ctor(_c_3011, 1.0));
return generateOutput();
}

// INITIAL HLSL END



