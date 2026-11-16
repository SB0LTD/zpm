// Uniforms

uniform float2 _u_resolution : register(c0);
#ifdef ANGLE_ENABLE_LOOP_FLATTEN
#define LOOP [loop]
#define FLATTEN [flatten]
#else
#define LOOP
#define FLATTEN
#endif

#define ATOMIC_COUNTER_ARRAY_STRIDE 4


// Varyings
static  float4 _v_color = {0, 0, 0, 0};
static float4 gl_FragCoord = float4(0, 0, 0, 0);

static float4 gl_Color[1] = {float4(0, 0, 0, 0)};

cbuffer DriverConstants : register(b1)
{
    float4 dx_ViewCoords : packoffset(c1);
    float2 dx_FragCoordOffset : packoffset(c3);
    float3 dx_DepthFront : packoffset(c2);
    float2 dx_ViewScale : packoffset(c3.z);
    uint dx_Misc : packoffset(c2.w);
    struct SamplerMetadata
    {
        int baseLevel;
        int wrapModes;
        int2 padding;
        int4 intBorderColor;
    };
    SamplerMetadata samplerMetadata[1] : packoffset(c4);
};




void gl_main()
{
float2 _uv = (gl_FragCoord.xy / _u_resolution);
(gl_Color[0] = float4(_uv, (gl_FragCoord.z * 0.5), frac((gl_FragCoord.w * 0.25))));
}

struct PS_INPUT
{
    float4 dx_Position : SV_Position;
    float4 gl_Position : TEXCOORD1;
    float4 gl_FragCoord : TEXCOORD2;
    float4 v0 : TEXCOORD0;
};

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
    float rhw = 1.0 / input.gl_FragCoord.w;
    gl_FragCoord.x = input.dx_Position.x - dx_FragCoordOffset.x;
    gl_FragCoord.y = input.dx_Position.y - dx_FragCoordOffset.y;
    gl_FragCoord.z = input.dx_Position.z;
    gl_FragCoord.w = rhw;
    _v_color = input.v0;

    gl_main();

    return generateOutput();
}
