// ANGLE's own HLSL for a WebGL program (cube_env), captured from Chromium's ANGLE
// (Direct3D 11 renderer) with WEBGL_debug_shaders; DynamicHLSL's stubs
// filled as ANGLE's link does.
struct PS_INPUT
{
    float4 dx_Position : SV_Position;
    float4 gl_Position : TEXCOORD1;
    float3 v0 : TEXCOORD0;
};

// INITIAL HLSL BEGIN

#pragma warning( disable: 3081 3556 3557 3571 )
// Uniforms

static const uint _u_env = 0;
static const uint textureIndexOffsetCube = 0;
static const uint samplerIndexOffsetCube = 0;
uniform TextureCube<float4> texturesCube[1] : register(t0);
uniform SamplerState samplersCube[1] : register(s0);
#ifdef ANGLE_ENABLE_LOOP_FLATTEN
#define LOOP [loop]
#define FLATTEN [flatten]
#else
#define LOOP
#define FLATTEN
#endif
// Varyings
static  float3 _v_dir = {0, 0, 0};

static float4 gl_Color[1] =
{
    float4(0, 0, 0, 0)
};

cbuffer DriverConstants : register(b1)
{
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

#define GL_USES_FRAG_COLOR
float4 gl_textureCube(uint samplerIndex, float3 t)
{
    const uint textureIndex = samplerIndex - textureIndexOffsetCube;
    const uint samplerArrayIndex = samplerIndex - samplerIndexOffsetCube;
    return texturesCube[textureIndex].Sample(samplersCube[samplerArrayIndex], float3(t.x, t.y, t.z));
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
    _v_dir = input.v0;

(gl_Color[0] = gl_textureCube(_u_env, normalize(_v_dir)));
return generateOutput();
}

// INITIAL HLSL END



