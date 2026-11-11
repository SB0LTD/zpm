float4 vec4_ctor(float3 x0, float x1)
{
    return float4(x0, x1);
}
// Uniforms

uniform float4x4 _u_bones[4] : register(c0);
uniform float4x4 _u_viewProj : register(c16);
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
static float4 _a_weights = {0, 0, 0, 0};
static float4 _a_indices = {0, 0, 0, 0};

static float4 gl_Position = float4(0, 0, 0, 0);

// Varyings
static  float4 _v_weights = {0, 0, 0, 0};

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
    float4 _a_weights : TEXCOORD1;
    float4 _a_indices : TEXCOORD2;
};

void initAttributes(VS_INPUT input)
{
    _a_position = input._a_position;
    _a_weights = input._a_weights;
    _a_indices = input._a_indices;
}

struct VS_OUTPUT
{
    float4 dx_Position : SV_Position;
    float4 gl_Position : TEXCOORD1;
    float4 v0 : TEXCOORD0;
};

void gl_main()
{
float4 _p = vec4_ctor(_a_position, 1.0);
float4 _skinned = {0.0, 0.0, 0.0, 0.0};
{ LOOP for(int _k = 0; (_k < 2); (++_k))
{
int _bi = int(clamp((_a_indices[_k] * 2.0), 0.0, 3.0));
(_skinned += (mul(transpose(_u_bones[_bi]), _p) * _a_weights[_k]));
}
}
(_skinned += (mul(transpose(_u_bones[0]), _p) * (1.0 - (_a_weights.x + _a_weights.y))));
(_v_weights = _a_weights);
(gl_Position = mul(transpose(_u_viewProj), _skinned));
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
    output.v0 = _v_weights;
    return output;
}

VS_OUTPUT main(VS_INPUT input){
    initAttributes(input);

    gl_main();

    return generateOutput(input);
}
