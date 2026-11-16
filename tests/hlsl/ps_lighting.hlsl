// Uniforms

uniform float3 _u_lightPos : register(c0);
uniform float3 _u_eye : register(c1);
uniform float4 _u_albedo : register(c2);
uniform float _u_shininess : register(c3);
#ifdef ANGLE_ENABLE_LOOP_FLATTEN
#define LOOP [loop]
#define FLATTEN [flatten]
#else
#define LOOP
#define FLATTEN
#endif

#define ATOMIC_COUNTER_ARRAY_STRIDE 4


// Varyings
static  float3 _v_normal = {0, 0, 0};
static  float3 _v_worldPos = {0, 0, 0};
static  float _v_diffuse = {0};

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


float4 vec4_ctor(float3 x0, float x1)
{
    return float4(x0, x1);
}


void gl_main()
{
float3 _n = normalize(_v_normal);
float3 _l = normalize((_u_lightPos - _v_worldPos));
float3 _v = normalize((_u_eye - _v_worldPos));
float3 _r = reflect((-_l), _n);
float _spec = pow(max(dot(_r, _v), 0.0), _u_shininess);
float _diff = clamp(dot(_n, _l), 0.0, 1.0);
float3 _col = lerp((_u_albedo.xyz * _diff), float3(1.0, 1.0, 1.0), (_spec * 0.5));
(gl_Color[0] = vec4_ctor((_col + (_v_diffuse * 0.1)), _u_albedo.w));
}

struct PS_INPUT
{
    float4 dx_Position : SV_Position;
    float4 gl_Position : TEXCOORD1;
    float3 v0 : TEXCOORD0;
    float3 v1 : TEXCOORD2;
    float v2 : TEXCOORD3;
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
    _v_normal = input.v0.xyz;
    _v_worldPos = input.v1.xyz;
    _v_diffuse = input.v2.x;

    gl_main();

    return generateOutput();
}
