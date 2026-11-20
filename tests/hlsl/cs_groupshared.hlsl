// Groupshared memory: an array reduced in steps with barriers (a loop),
// a struct, a matrix, a 2D array; each barrier's flags.
struct Tile
{
    float3 sum;
    uint count;
};

RWStructuredBuffer<float> output;
RWByteAddressBuffer stats;
StructuredBuffer<float> input;

groupshared float values[64];
groupshared Tile tile;
groupshared float2x2 rot;
groupshared uint hist[4][4];

[numthreads(64, 1, 1)]
void main(uint3 id : SV_DispatchThreadID, uint gi : SV_GroupIndex, uint3 group : SV_GroupID)
{
    values[gi] = input[id.x];
    hist[gi % 4][gi / 16] = gi;
    if (gi == 0)
    {
        tile.sum = float3(0, 1, 2);
        tile.count = group.x;
        rot = float2x2(0.5, -0.25, 0.25, 0.5);
    }
    GroupMemoryBarrierWithGroupSync();
    [loop]
    for (uint step = 32; step > 0; step >>= 1)
    {
        if (gi < step)
            values[gi] += values[gi + step];
        GroupMemoryBarrierWithGroupSync();
    }
    float2 r = mul(rot, float2(values[0], gi));
    output[id.x] = r.x + r.y + tile.sum.y + tile.count + hist[(gi + 1) % 4][(gi + 2) % 4];
    AllMemoryBarrierWithGroupSync();
    stats.Store(id.x * 4, asuint(values[gi % 8]));
    DeviceMemoryBarrierWithGroupSync();
    stats.Store(id.x * 4 + 512, stats.Load(((id.x + 1) % 64) * 4));
}
