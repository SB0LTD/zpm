// The thread ids, memory read and written inside loops, branches and a
// switch, a helper function taking a UAV, dynamically indexed members.
struct Cell
{
    uint4 ids;
    float values[4];
};

RWStructuredBuffer<Cell> cells;
RWBuffer<float> trace;
RWTexture3D<uint> volume;
RWTexture2DArray<float2> layers;

cbuffer Limits
{
    uint iterations;
    uint pick;
};

void bump(RWBuffer<float> b, uint at, float by)
{
    b[at] = b[at] + by;
}

[numthreads(4, 4, 2)]
void main(uint3 id : SV_DispatchThreadID, uint3 group : SV_GroupID, uint3 local : SV_GroupThreadID, uint flat : SV_GroupIndex)
{
    uint at = flat + group.x * 32;
    cells[at].ids = uint4(id.x, group.y, local.z, flat);
    [loop]
    for (uint k = 0; k < iterations; k++)
    {
        cells[at].values[k % 4] += k;
        if (cells[at].values[(k + pick) % 4] > 2)
            break;
    }
    switch (pick)
    {
    case 0:
        bump(trace, at, 1);
        break;
    case 1:
        bump(trace, at, cells[at].values[1]);
        break;
    default:
        bump(trace, at, -1);
        break;
    }
    uint w, h, d;
    volume.GetDimensions(w, h, d);
    volume[id] = volume[id] + w * h + d;
    uint lw, lh, ln;
    layers.GetDimensions(lw, lh, ln);
    layers[uint3(id.xy, id.z % ln)] = float2(lw, cells[at].values[id.x % 4]);
}
