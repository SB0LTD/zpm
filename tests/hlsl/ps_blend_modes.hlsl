// Uniforms

static const uint _s_tex = 0;
uniform Texture2D<float4> textures2D[1] : register(t0);
uniform SamplerState samplers2D[1] : register(s0);
uniform int _u_mode : register(c0);
uniform float _u_opacity : register(c1);
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
float3 Multiply(float3 Cb, float3 Cs) { return Cb * Cs; }
float3 Screen(float3 Cb, float3 Cs) { return Cb + Cs - (Cb * Cs); }
float3 HardLight(float3 Cb, float3 Cs) {
    float3 m = Multiply(Cb, 2.0 * Cs);
    float3 s = Screen(Cb, 2.0 * Cs - 1.0);
    float3 edge = float3(0.5, 0.5, 0.5);
    return lerp(m, s, step(edge, Cs));
}
float ColorDodge(float Cb, float Cs) {
    if (Cb == 0.0) return 0.0;
    else if (Cs == 1.0) return 1.0;
    else return min(1.0, Cb / (1.0 - Cs));
}
float Lum(float3 c) { return dot(c, float3(0.3, 0.59, 0.11)); }
float3 ClipColor(float3 C) {
    float L = Lum(C);
    float n = min(C.r, min(C.g, C.b));
    float x = max(C.r, max(C.g, C.b));
    if (n < 0.0) C = L + (((C - L) * L) / (L - n));
    if (x > 1.0) C = L + (((C - L) * (1.0 - L)) / (x - L));
    return C;
}


void gl_main()
{
float4 _src = gl_texture2D(_s_tex, _v_color.xy);
float3 _dst = _v_color.zwx;
float3 _res = _src.xyz;
switch (_u_mode) {
case 1: _res = Multiply(_dst, _src.xyz); break;
case 2: _res = Screen(_dst, _src.xyz); break;
case 3: _res = HardLight(_dst, _src.xyz); break;
case 4: _res = float3(ColorDodge(_dst.x, _src.x), ColorDodge(_dst.y, _src.y), ColorDodge(_dst.z, _src.z)); break;
default: _res = ClipColor(_dst + _src.xyz - 0.5); break;
}
(gl_Color[0] = float4(_res, _src.w * _u_opacity));
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
