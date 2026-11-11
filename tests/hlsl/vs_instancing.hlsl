// Uniforms

uniform float4 _u_offsets[4] : register(c0);
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
static int gl_InstanceID;
static int gl_VertexID;

static float4 gl_Position = float4(0, 0, 0, 0);

// Varyings
static nointerpolation int _v_id = {0};
static  float4 _v_tint = {0, 0, 0, 0};

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
    uint d3d_InstanceID : SV_InstanceID;
    uint d3d_VertexID : SV_VertexID;
};

void initAttributes(VS_INPUT input)
{
    _a_position = input._a_position;
    gl_InstanceID = input.d3d_InstanceID;
    gl_VertexID = input.d3d_VertexID + dx_VertexID;
}

struct VS_OUTPUT
{
    float4 dx_Position : SV_Position;
    float4 gl_Position : TEXCOORD2;
    nointerpolation int v0 : TEXCOORD0;
    float4 v1 : TEXCOORD1;
};

void gl_main()
{
(gl_Position = (_a_position + (_u_offsets[(gl_InstanceID & 3)] * 0.0)));
(_v_id = ((gl_VertexID * 4) + gl_InstanceID));
(_v_tint = _u_offsets[(gl_VertexID % 3)]);
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
    output.v0 = _v_id;
    output.v1 = _v_tint;
    return output;
}

VS_OUTPUT main(VS_INPUT input){
    initAttributes(input);

    gl_main();

    return generateOutput(input);
}
