// Typed UAVs and textures in a compute shader: RWTexture2D, RWBuffer,
// Texture2D's Load, SampleLevel, Gather and operator[], a comparison
// sampler's SampleCmpLevelZero, Buffer<T>, GetDimensions of each.
RWTexture2D<float4> image : register(u0);
RWBuffer<uint> counts;
RWBuffer<float> sums;
Texture2D<float4> colors;
Texture2D<float> depth_comparison;
Buffer<float4> table;
SamplerState linearSampler;
SamplerComparisonState shadowSampler;

cbuffer Params
{
    float4 scale;
    uint2 size;
    float level;
};

[numthreads(8, 8, 1)]
void main(uint3 id : SV_DispatchThreadID)
{
    uint w, h;
    image.GetDimensions(w, h);
    uint tw, th, levels;
    colors.GetDimensions(0, tw, th, levels);
    uint n;
    table.GetDimensions(n);
    float2 uv = (float2(id.xy) + 0.5) / float2(size);
    float4 c = colors.SampleLevel(linearSampler, uv, level);
    c += colors.Load(int3(id.xy % 8, 0)) * 0.5;
    c += colors[id.xy % 8] * 0.25;
    c += colors.Gather(linearSampler, uv) * 0.125;
    c.x += depth_comparison.SampleCmpLevelZero(shadowSampler, uv, 0.5);
    c += table[id.x % 4] + table.Load(id.y % 4);
    image[id.xy] = c * scale + image[id.xy] + float4(w, h, tw + th + levels, n) * 0.001;
    counts[id.y * 16 + id.x] = counts[id.y * 16 + id.x] * 3 + w;
    sums[id.x + id.y * 16] = dot(c, scale);
}
