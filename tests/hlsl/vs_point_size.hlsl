// Uniforms

uniform float _u_pointSize : register(c0);
uniform float4x4 _u_mvp : register(c1);
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

static float4 gl_Position = float4(0, 0, 0, 0);
static float gl_PointSize = float(1);

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
};

void initAttributes(VS_INPUT input)
{
    _a_position = input._a_position;
}

struct VS_OUTPUT
{
    float4 dx_Position : SV_Position;
    float4 gl_Position : TEXCOORD0;
    float gl_PointSize : PSIZE;
};

void gl_main()
{
(gl_Position = mul(transpose(_u_mvp), _a_position));
(gl_PointSize = (_u_pointSize * (1.0 + _a_position.z)));
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
    output.gl_PointSize = gl_PointSize;
    return output;
}

VS_OUTPUT main(VS_INPUT input){
    initAttributes(input);

    gl_main();

    return generateOutput(input);
}
