// Uniforms

uniform int _u_mode : register(c0);
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
int _sel = int((_v_color.x * 5.0));
float4 _c = {0.0, 0.0, 0.0, 1.0};
switch(_sel)
{
case 0:
(_c.x = 1.0);
break;
case 1:
(_c.y = 1.0);
(_c.z = 0.25);
break;
case 2:
case 3:
(_c.z = 0.5);
break;
case 4:
{
(_c.xy = float2(0.25, 0.75));
break;
}
default:
(_c.w = 0.5);
break;
}
switch(_u_mode)
{
case 2:
(_c *= 0.5);
break;
default:
break;
}
(gl_Color[0] = _c);
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
