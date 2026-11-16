#define PI 3.14159265
#define SQR(x) ((x) * (x))
#define MIX3(a, b, t) lerp(a, b, t)
#define CAT(a, b) a##b
#ifdef ANGLE_ENABLE_LOOP_FLATTEN
#define LOOP [loop]
#else
#define LOOP
#endif
#if defined(PI) && (SQR(2) == 4)
#define GOOD 1
#elif 1
#define GOOD 0
#else
#error unreachable
#endif
#pragma warning(disable: 3557)

struct PS_INPUT
{
    float4 dx_Position : SV_Position;
    float4 v0 : TEXCOORD0;
};

float4 main(PS_INPUT input) : SV_Target0
{
    float CAT(my, Value) = SQR(input.v0.x) * PI;
    float4 c = MIX3(input.v0, float4(1, 0, 0, 1), 0.25);
#if GOOD
    c.w = frac(myValue);
#else
    c.w = 0.0;
#endif
    LOOP for (int i = 0; i < 2; i++) { c.xyz *= 0.9; }
    return c;
}
