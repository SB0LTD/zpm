// Structured and byte address buffers: struct elements laid out tightly
// (a float3 then a uint, a column-major and a row-major matrix, an array),
// members read and written one at a time, whole elements copied, Load2-4
// and Store2-4, GetDimensions.
struct Particle
{
    float3 position;
    uint flags;
    float2 uv;
    float3x3 basis;
    row_major float2x3 tilt;
    int ids[3];
};

StructuredBuffer<Particle> particlesIn;
StructuredBuffer<float> weights;
StructuredBuffer<uint3> triples;
RWStructuredBuffer<Particle> particlesOut;
RWStructuredBuffer<float4> colorsOut;
ByteAddressBuffer rawIn;
RWByteAddressBuffer rawOut;

[numthreads(16, 1, 1)]
void main(uint3 id : SV_DispatchThreadID)
{
    uint i = id.x;
    Particle p = particlesIn[i];
    float w = weights[i];
    uint3 t = triples[i];
    uint count, stride, bytes;
    particlesIn.GetDimensions(count, stride);
    rawIn.GetDimensions(bytes);
    p.position += float3(w, t.x, p.basis[1][2]);
    p.flags ^= t.y + count + stride + bytes;
    p.ids[1] += p.ids[2] * 2;
    particlesOut[i] = p;
    particlesOut[i + 32].uv = p.uv.yx;
    particlesOut[i + 32].basis[2] = p.basis._m01_m11_m21;
    particlesOut[i + 32].tilt._m12 = p.tilt[1].x;
    particlesOut[i + 32].ids[t.z % 3] = (int)i;
    colorsOut[i] = float4(p.uv, mul(p.basis, p.position).xy) + colorsOut[i + 1];
    uint a = rawIn.Load(i * 4);
    uint2 b = rawIn.Load2(i * 8 + 4);
    uint3 c = rawIn.Load3(i * 12);
    uint4 d = rawOut.Load4(i * 16 + 512);
    rawOut.Store(i * 4, a + b.y);
    rawOut.Store2(i * 8 + 64, b + c.xy);
    rawOut.Store3(i * 12 + 256, c * 3);
    rawOut.Store4(i * 16 + 1024, d.wzyx);
}
