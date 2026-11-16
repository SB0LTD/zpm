// Uniforms

uniform float _u_threshold : register(c0);
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


float classify_float(in float _x)
{
FLATTEN if ((_x < 0.25))
{
return 0.1;
}
FLATTEN if ((_x < 0.5))
{
return 0.4;
}
return 0.9;
}
float find_float(in float _target)
{
float _v = 0.0;
{ LOOP for(int _i = 0; (_i < 10); (++_i))
{
(_v += 0.1);
FLATTEN if ((_v > _target))
{
return _v;
}
}
}
return -1.0;
}


void gl_main()
{
float _a = classify_float(_v_color.x);
float _b = find_float(_v_color.y);
float _c = classify_float(_v_color.z) + find_float(_u_threshold);
(gl_Color[0] = float4(_a, _b, (_c * 0.5), 1.0));
FLATTEN if ((_v_color.w > 0.9))
{
(gl_Color[0] = float4(1.0, 0.0, 1.0, 1.0));
return;
}
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
