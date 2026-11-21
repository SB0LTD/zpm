// UAVs in a pixel shader (ps_5_0): numbered after the render targets
// written, an explicit register kept, a typed load, an atomic counter,
// DeviceMemoryBarrier.
RWTexture2D<float4> history;
RWByteAddressBuffer counter;
RWStructuredBuffer<uint> marks : register(u4);

struct Out
{
    float4 color : SV_Target0;
    float4 extra : SV_Target1;
};

Out main(float4 pos : SV_Position, float2 uv : TEXCOORD0)
{
    Out o;
    uint2 px = uint2(pos.xy);
    uint ticket;
    counter.InterlockedAdd(0, 1, ticket);
    float4 before = history[px];
    history[px] = float4(uv, ticket, 1);
    marks[px.y * 16 + px.x] = ticket;
    DeviceMemoryBarrier();
    o.color = before + float4(uv, 0, 1);
    o.extra = history[px] * 0.5;
    return o;
}
