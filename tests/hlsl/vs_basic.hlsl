float4 vec4_ctor(float2 x0, float x1, float x2)
{
    return float4(x0, x1, x2);
}
// Uniforms

uniform float4x4 _u_mvp : register(c0);
uniform float4 _u_tint : register(c4);
uniform float _u_scale[3] : register(c5);
#ifdef ANGLE_ENABLE_LOOP_FLATTEN
#define LOOP [loop]
#define FLATTEN [flatten]
#else
#define LOOP
#define FLATTEN
#endif

#define ATOMIC_COUNTER_ARRAY_STRIDE 4


// Attributes
static float2 _a_position = {0, 0};
static float2 _a_texcoord = {0, 0};

static float4 gl_Position = float4(0, 0, 0, 0);

// Varyings
static  float2 _v_texcoord = {0, 0};
static  float4 _v_color = {0, 0, 0, 0};

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
    float2 _a_position : TEXCOORD0;
    float2 _a_texcoord : TEXCOORD1;
};

void initAttributes(VS_INPUT input)
{
    _a_position = input._a_position;
    _a_texcoord = input._a_texcoord;
}

struct VS_OUTPUT
{
    float4 dx_Position : SV_Position;
    float4 gl_Position : TEXCOORD2;
    float4 v0 : TEXCOORD0;
    float2 v1 : TEXCOORD1;
};

;
;
;
void gl_main()
{
(gl_Position = mul(transpose(_u_mvp), vec4_ctor(_a_position, 0.0, 1.0)));
(_v_texcoord = (_a_texcoord * _u_scale[1]));
(_v_color = (_u_tint * _u_scale[2]));
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
    output.v0 = _v_color;
    output.v1 = _v_texcoord;
    return output;
}

VS_OUTPUT main(VS_INPUT input){
    initAttributes(input);

    gl_main();

    return generateOutput(input);
}
