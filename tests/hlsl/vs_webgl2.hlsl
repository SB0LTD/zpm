// Uniforms

uniform float4x4 _u_mvp : register(c0);
uniform int _u_mode : register(c4);
uniform uint _u_bits : register(c5);
#ifdef ANGLE_ENABLE_LOOP_FLATTEN
#define LOOP [loop]
#define FLATTEN [flatten]
#else
#define LOOP
#define FLATTEN
#endif

#define ATOMIC_COUNTER_ARRAY_STRIDE 4


// Attributes
static float4 _a_position = {0, 0, 0, 0};
static int4 _a_ids = {0, 0, 0, 0};
static uint2 _a_flags = {0, 0};

static float4 gl_Position = float4(0, 0, 0, 0);

// Varyings
static nointerpolation int _v_mode = {0};
static nointerpolation uint2 _v_flags = {0, 0};
static  float3 _v_color = {0, 0, 0};
static  noperspective float2 _v_np = {0, 0};
static  centroid float _v_cent = {0};

cbuffer DriverConstants : register(b1)
{
    float3 dx_DepthRange : packoffset(c0);
    float2 dx_ViewScale : packoffset(c1);
    float clipControlOrigin : packoffset(c1.z);
    float clipControlZeroToOne : packoffset(c1.w);
    uint dx_VertexID : packoffset(c2.x);
    uint clipDistancesEnabled : packoffset(c2.y);
};

struct gl_DepthRangeParameters
{
    float near;
    float far;
    float diff;
};

static gl_DepthRangeParameters gl_DepthRange = {dx_DepthRange.x, dx_DepthRange.y, dx_DepthRange.z};


struct VS_INPUT
{
    float4 _a_position : TEXCOORD0;
    int4 _a_ids : TEXCOORD1;
    uint2 _a_flags : TEXCOORD2;
};

void initAttributes(VS_INPUT input)
{
    _a_position = input._a_position;
    _a_ids = input._a_ids;
    _a_flags = input._a_flags;
}

struct VS_OUTPUT
{
    float4 dx_Position : SV_Position;
    float4 gl_Position : TEXCOORD5;
    nointerpolation int v0 : TEXCOORD0;
    nointerpolation uint2 v1 : TEXCOORD1;
    float3 v2 : TEXCOORD2;
    noperspective float2 v3 : TEXCOORD3;
    centroid float v4 : TEXCOORD4;
};

void gl_main()
{
(gl_Position = mul(transpose(_u_mvp), _a_position));
(_v_mode = (_u_mode + _a_ids.x));
(_v_flags = (_a_flags | uint2(_u_bits, (_u_bits << 1))));
float3 _c = float3(_a_ids.yzw) * 0.25;
switch(_u_mode)
{
case 1:
(_c = _c.zyx);
break;
case 2:
(_c *= 2.0);
break;
}
(_v_color = _c);
(_v_np = _a_position.xy);
(_v_cent = _a_position.z);
}

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
    output.v0 = _v_mode;
    output.v1 = _v_flags;
    output.v2 = _v_color;
    output.v3 = _v_np;
    output.v4 = _v_cent;
    return output;
}

VS_OUTPUT main(VS_INPUT input){
    initAttributes(input);

    gl_main();

    return generateOutput(input);
}
