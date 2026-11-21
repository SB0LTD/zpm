// Tiled lighting, as engines write it: a 2D groupshared tile, a row-major
// groupshared matrix, a structured buffer of structs with a matrix and a
// bool, a loop over them, atomics on groupshared memory and a buffer, an
// early return after the last barrier.
#define TILE 16
struct Light { float4x4 xform; float3 color; float radius; bool on; };
StructuredBuffer<Light> lights : register(t3);
Texture2D<float> depthTex;
RWTexture2D<float4> outColor;
RWStructuredBuffer<uint> lightCount;
cbuffer Frame : register(b1) { float4x4 viewProj; uint numLights; uint2 screen; };
groupshared float cache[TILE + 2][TILE + 2];
groupshared uint tileLights;
groupshared row_major float2x3 rm;

float4 shade(Light l, float d) { return float4(l.color * d / l.radius, 1) * (l.on ? 1 : 0); }

[numthreads(TILE, TILE, 1)]
void main(uint3 DTid : SV_DispatchThreadID, uint3 gtid : SV_GroupThreadID, uint gi : SV_GroupIndex)
{
    uint2 dims;
    outColor.GetDimensions(dims.x, dims.y);
    if (gi == 0) { tileLights = 0; rm = float2x3(1, 2, 3, 4, 5, 6); }
    cache[gtid.y + 1][gtid.x + 1] = depthTex[min(DTid.xy, dims - 1)];
    GroupMemoryBarrierWithGroupSync();
    // (neighbours inside the tile: every cell read was written)
    float d = cache[gtid.y + 1][(gtid.x + 1) % TILE + 1] + cache[(gtid.y + 1) % TILE + 1][gtid.x + 1] + rm[gi % 2][gi % 3];
    float4 c = 0;
    [loop]
    for (uint i = 0; i < numLights; i++)
    {
        Light l = lights[i];
        float4 p = mul(l.xform, float4(DTid.xy, d, 1));
        if (p.z > 0)
        {
            c += shade(l, p.z);
            InterlockedAdd(tileLights, 1);
        }
    }
    GroupMemoryBarrierWithGroupSync();
    uint before;
    if (gi == 0)
        InterlockedAdd(lightCount[DTid.x / TILE + DTid.y / TILE * 64], tileLights, before);
    if (any(DTid.xy >= screen))
        return;
    outColor[DTid.xy] = mul(viewProj, c);
}
