// Uniforms

static const uint _s_a = 0;
static const uint _s_b = 1;
static const uint _s_arr = 2;
uniform Texture2D<float4> textures2D[2] : register(t0);
uniform SamplerState samplers2D[2] : register(s0);
static const uint textureIndexOffset2DArray = 2;
static const uint samplerIndexOffset2DArray = 2;
uniform Texture2DArray<float4> textures2DArray[1] : register(t2);
uniform SamplerState samplers2DArray[1] : register(s2);
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


float4 gl_texture2D(uint samplerIndex, float2 t)
{
    return textures2D[samplerIndex].Sample(samplers2D[samplerIndex], float2(t.x, t.y));
}
float4 gl_texture2DArray(uint samplerIndex, float3 t)
{
    const uint textureIndex = samplerIndex - textureIndexOffset2DArray;
    const uint samplerArrayIndex = samplerIndex - samplerIndexOffset2DArray;
    return textures2DArray[textureIndex].Sample(samplers2DArray[samplerArrayIndex], float3(t.x, t.y, t.z));
}


void gl_main()
{
float4 _x = gl_texture2D(_s_a, _v_color.xy);
float4 _y = gl_texture2D(_s_b, _v_color.zw);
float4 _z = gl_texture2DArray(_s_arr, float3(_v_color.xy, 1.0));
(gl_Color[0] = (_x * 0.5) + (_y * 0.25) + (_z * 0.25));
}

struct PS_INPUT
{
    float4 dx_Position : SV_Position;
    float4 gl_Position : TEXCOORD1;
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
    _v_color = input.v0;

    gl_main();

    return generateOutput();
}
