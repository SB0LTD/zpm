float3x3 mat3_ctor(float4x4 x0)
{
    return float3x3(x0[0][0], x0[0][1], x0[0][2], x0[1][0], x0[1][1], x0[1][2], x0[2][0], x0[2][1], x0[2][2]);
}
float4 vec4_ctor(float3 x0, float x1)
{
    return float4(x0, x1);
}
// Uniforms

uniform float4x4 _u_model : register(c0);
uniform float4x4 _u_viewProj : register(c4);
uniform float3 _u_lightDir : register(c8);
uniform float3x3 _u_normalMatrix : register(c9);
#ifdef ANGLE_ENABLE_LOOP_FLATTEN
#define LOOP [loop]
#define FLATTEN [flatten]
#else
#define LOOP
#define FLATTEN
#endif

#define ATOMIC_COUNTER_ARRAY_STRIDE 4


// Attributes
static float3 _a_position = {0, 0, 0};
static float3 _a_normal = {0, 0, 0};

static float4 gl_Position = float4(0, 0, 0, 0);

// Varyings
static  float3 _v_normal = {0, 0, 0};
static  float _v_diffuse = {0};
static  float3 _v_worldPos = {0, 0, 0};

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
    float3 _a_position : TEXCOORD0;
    float3 _a_normal : TEXCOORD1;
};

void initAttributes(VS_INPUT input)
{
    _a_position = input._a_position;
    _a_normal = input._a_normal;
}

struct VS_OUTPUT
{
    float4 dx_Position : SV_Position;
    float4 gl_Position : TEXCOORD3;
    float3 v0 : TEXCOORD0;
    float3 v1 : TEXCOORD1;
    float v2 : TEXCOORD2;
};

void gl_main()
{
float4 _world = mul(transpose(_u_model), vec4_ctor(_a_position, 1.0));
(_v_worldPos = _world.xyz);
(_v_normal = normalize(mul(transpose(_u_normalMatrix), _a_normal)));
(_v_diffuse = max(dot(_v_normal, normalize((-_u_lightDir))), 0.0));
float3x3 _m3 = mat3_ctor(_u_model);
(_v_normal += (0.0 * mul(transpose(_m3), _a_normal)));
(gl_Position = mul(transpose(_u_viewProj), _world));
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
    output.v0 = _v_normal;
    output.v1 = _v_worldPos;
    output.v2 = _v_diffuse;
    return output;
}

VS_OUTPUT main(VS_INPUT input){
    initAttributes(input);

    gl_main();

    return generateOutput(input);
}
