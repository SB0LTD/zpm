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

// Early returns: inside an if, and inside a loop (ret inside flow).
float4 ps_early(VSOut i) : SV_Target
{
    if (i.color.r > 0.75)
        return float4(1, 0, 0, 1);
    float4 acc = 0;
    [loop] for (int k = 0; k < 8; k++) {
        acc += i.color * 0.125;
        if (acc.g > i.color.b * 0.5)
            return acc;
    }
    return float4(0, 0, 1, 1);
}

// A pixel shader reading a structured buffer (t1): the entry the colour's
// red names, times the tint.
StructuredBuffer<float4> sb : register(t1);

float4 ps_sbuf(VSOut i) : SV_Target
{
    return sb[(uint)(i.color.x * 3.0 + 0.5)] * tint;
}

// The RTX's texture unit's forms: a 2D array's comparisons (one at a
// texel offset), a mipmapped texture at a level between two, a texel of
// its second level fetched (ld, at an offset), and a cube map across a
// face's edges (its taps fetched through the unit, the filter the
// program's).
Texture2DArray<float> shadow : register(t0);
SamplerComparisonState cmp : register(s0);
Texture2D mipped : register(t1);
SamplerState lin : register(s1);
TextureCube sky : register(t2);

float4 ps_unit(VSOut i) : SV_Target
{
    float2 uv = i.color.xy;
    float s = shadow.SampleCmpLevelZero(cmp, float3(uv, 1), 0.5);
    s += shadow.SampleCmpLevelZero(cmp, float3(uv, 2), 0.5, int2(1, -1));
    float4 m = mipped.SampleLevel(lin, uv, 0.5);
    float4 t = mipped.Load(int3(uv * 4.0, 1), int2(1, 0));
    float4 c = sky.SampleLevel(lin, float3(1.0, uv.y * 2.4 - 1.2, uv.x * 2.4 - 1.2), 0);
    return float4(s * 0.5, m.g, m.b * 0.5 + t.r * 0.5, t.g * 0.5 + c.r * 0.25 + c.b * 0.25);
}
