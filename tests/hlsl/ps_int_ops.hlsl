// Uniforms

uniform int _u_shift : register(c0);
uniform uint _u_mask : register(c1);
uniform int4 _u_ivec : register(c2);
static const uint _s_tex = 0;
uniform Texture2D<float4> textures2D[1] : register(t0);
uniform SamplerState samplers2D[1] : register(s0);
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


float4 gl_texture2DFetch(uint samplerIndex, int2 t, int mip)
{
    const uint textureIndex = samplerIndex;
    const uint samplerArrayIndex = samplerIndex;
    return textures2D[textureIndex].Load(int3(t.x, t.y, mip));
}
int2 gl_textureSize(uint samplerIndex, int lod)
{
    const uint textureIndex = samplerIndex;
    const uint samplerArrayIndex = samplerIndex;
    int baseLevel = 0;
    uint width; uint height; uint numberOfLevels;
    textures2D[textureIndex].GetDimensions(baseLevel, width, height, numberOfLevels);
    width = max(width >> lod, 1);
    height = max(height >> lod, 1);
    return int2(width, height);
}


void gl_main()
{
int _x = int((_v_color.x * 100.0));
int _y = int((_v_color.y * 100.0)) - 37;
uint _u = uint((_v_color.z * 200.0));
int _a = ((_x << _u_shift) ^ (_x >> 1)) | 7;
int _b = (_y / 3) + (_y % 5);
uint _c = ((_u / 7u) + (_u % 3u)) & _u_mask;
int _d = (-_y) * _u_ivec.x + abs(_y) - min(_x, _y) + max(_x, _u_ivec.y);
uint _e = (_u >> 2u) + (~_u & 15u);
int2 _sz = gl_textureSize(_s_tex, 0);
float4 _t = gl_texture2DFetch(_s_tex, int2((_x % _sz.x), 1), 0);
(gl_Color[0] = float4((float((_a & 255)) / 255.0), (float(((_b + 64) & 255)) / 255.0), (float((_c + (_e & 15u))) / 64.0), (float(_d & 63) / 63.0)) * 0.5 + (_t * 0.5));
(gl_Color[0].x += float(_sz.y) * 0.001);
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
