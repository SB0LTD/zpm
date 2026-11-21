// Interlocked operations on typed UAVs, byte address and structured
// buffers and groupshared memory, with and without the original value
// (each thread's own address where the original value is kept, so the
// results do not depend on the threads' order).
struct Slot
{
    uint hits;
    int low;
    int high;
};

RWBuffer<uint> totals;
RWTexture2D<int> grid;
RWByteAddressBuffer raw;
RWStructuredBuffer<Slot> slots;
RWStructuredBuffer<uint4> results;
groupshared uint shared_sum;
groupshared int shared_min[4];

[numthreads(16, 4, 1)]
void main(uint3 id : SV_DispatchThreadID, uint3 gt : SV_GroupThreadID, uint gi : SV_GroupIndex)
{
    if (gi == 0)
        shared_sum = 0;
    if (gi < 4)
        shared_min[gi] = 1000;
    GroupMemoryBarrierWithGroupSync();
    InterlockedAdd(shared_sum, gi);
    InterlockedMin(shared_min[gt.y], (int)gt.x - 8);
    InterlockedAdd(totals[0], 1);
    InterlockedMax(totals[1], id.x * 7 % 13);
    InterlockedOr(totals[2], 1u << (id.x % 32));
    InterlockedMin(grid[id.xy % 4], -(int)id.x);
    raw.InterlockedAdd(0, 2);
    raw.InterlockedXor(4, id.x);
    InterlockedAdd(slots[id.x % 8].hits, 1);
    InterlockedMin(slots[id.x % 8].low, (int)id.y - 2);
    InterlockedMax(slots[id.y].high, (int)id.x);
    uint own = id.y * 64 + id.x;
    uint o1, o2, o3, o4;
    InterlockedAdd(totals[16 + own], 5, o1);
    InterlockedExchange(totals[16 + own], o1 + 9, o2);
    InterlockedCompareExchange(totals[16 + own], o2 + 5, 77, o3);
    raw.InterlockedCompareExchange(64 + own * 4, 0, own, o4);
    raw.InterlockedCompareStore(64 + own * 4, own, own + 1);
    InterlockedCompareStore(totals[16 + own], 77, 78);
    GroupMemoryBarrierWithGroupSync();
    results[own] = uint4(o1 + o2 * 3, o3, o4, shared_sum + (uint)shared_min[gt.y]);
}
