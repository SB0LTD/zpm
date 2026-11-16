// Uniforms

uniform float4 _u_weights[8] : register(c0);
uniform int _u_count : register(c8);
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




void gl_main()
{
float4 _sum = {0.0, 0.0, 0.0, 0.0};
{ LOOP for(int _i = 0; (_i < 8); (++_i))
{
FLATTEN if ((_i >= _u_count))
{
break;
}
(_sum += (_u_weights[_i] * _v_color));
}
}
float _acc = 0.0;
{ for(int _j = 0; (_j < 4); (_j++))
{
FLATTEN if ((_j == 1))
{
continue;
}
(_acc += float(_j));
}
}
(gl_Color[0] = ((_sum * 0.25) + (_acc * 0.01)));
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
