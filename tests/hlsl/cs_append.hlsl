// Append and consume buffers, and a structured buffer's counter.
struct Item
{
    float2 at;
    uint id;
};

AppendStructuredBuffer<Item> found;
ConsumeStructuredBuffer<uint> work;
RWStructuredBuffer<uint> tickets;
globallycoherent RWByteAddressBuffer summary;

[numthreads(32, 1, 1)]
void main(uint3 id : SV_DispatchThreadID)
{
    uint job = work.Consume();
    Item it;
    it.at = float2(job, id.x);
    it.id = id.x * 2;
    if (job % 2 == 0)
        found.Append(it);
    uint t = tickets.IncrementCounter();
    tickets[t] = 1;
    uint n, stride;
    found.GetDimensions(n, stride);
    summary.Store(id.x * 4, n + stride);
}
