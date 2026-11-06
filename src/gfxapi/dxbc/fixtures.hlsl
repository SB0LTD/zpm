cbuffer Frame : register(b0)
{
    float4x4 mvp;
    float4 tint;
};

struct VSIn
{
    float3 pos : POSITION;
    float4 color : COLOR;
};

struct VSOut
{
    float4 pos : SV_Position;
    float4 color : COLOR;
};

VSOut vs_main(VSIn i)
{
    VSOut o;
    o.pos = mul(float4(i.pos, 1.0), mvp);
    o.color = i.color;
    return o;
}

float4 ps_main(VSOut i) : SV_Target
{
    return i.color * tint;
}

Texture2D tex : register(t0);
SamplerState smp : register(s0);

float4 ps_tex(VSOut i) : SV_Target
{
    float4 c = tex.Sample(smp, i.color.xy);
    if (c.a < 0.5)
        discard;
    float s = 0;
    [loop] for (int k = 0; k < 4; k++)
        s += c[k] * (k + 1);
    return float4(c.rgb * tint.rgb, frac(s));
}

float4 ps_int(VSOut i) : SV_Target
{
    uint x = (uint)(i.color.x * 255.0);
    int y = (int)(i.color.y * 255.0) - 128;
    uint m = (x << 3) ^ (x >> 1) | 7u;
    int d = y / 3;
    return float4(m / 255.0, d / 127.0, abs(y) / 128.0, (x & 1u) ? 1.0 : 0.0);
}
