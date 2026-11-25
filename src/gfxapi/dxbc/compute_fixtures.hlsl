// Compute shaders for gfxapi/dxbc's compute kernels (compute_test.sig),
// compiled by Microsoft's compiler (cs_5_0, default flags) into
// compute_fixtures.sig. Each one's result is known exactly: the test
// works it out in Sig and compares every word.

// Typed UAV: a texture read, scaled, and the thread's place added.
Texture2D<float4> cs_typed_src : register(t0);
RWTexture2D<float4> cs_typed_dst : register(u0);
cbuffer TypedParams : register(b0) { float4 cs_typed_scale; };

[numthreads(8, 8, 1)]
void cs_typed(uint3 id : SV_DispatchThreadID)
{
    float4 v = cs_typed_src.Load(int3(id.xy, 0));
    cs_typed_dst[id.xy] = v * cs_typed_scale + float4(id.x, id.y, 0, 0);
}

// Structured buffers: a struct read, changed and written; its count from
// GetDimensions.
struct Particle { float3 pos; float w; uint flags; };
StructuredBuffer<Particle> cs_struct_in : register(t0);
RWStructuredBuffer<Particle> cs_struct_out : register(u0);

[numthreads(64, 1, 1)]
void cs_structured(uint3 id : SV_DispatchThreadID)
{
    uint n, stride;
    cs_struct_in.GetDimensions(n, stride);
    if (id.x >= n) return;
    Particle p = cs_struct_in[id.x];
    p.pos += float3(1, 2, 3) * p.w;
    p.flags = p.flags * 2 + stride;
    cs_struct_out[id.x] = p;
}

// Raw buffers: four words read, reversed and offset by the thread.
ByteAddressBuffer cs_raw_in : register(t0);
RWByteAddressBuffer cs_raw_out : register(u0);

[numthreads(32, 1, 1)]
void cs_raw(uint3 id : SV_DispatchThreadID)
{
    uint4 v = cs_raw_in.Load4(id.x * 16);
    cs_raw_out.Store4(id.x * 16, v.wzyx + id.x);
    if (id.x == 0) {
        uint bytes;
        cs_raw_in.GetDimensions(bytes);
        cs_raw_out.Store(4096, bytes);
    }
}

// Groupshared memory and a barrier: each group's values reversed, with
// every thread id input.
groupshared float cs_shared_mem[64];
RWStructuredBuffer<float4> cs_shared_out : register(u0);

[numthreads(64, 1, 1)]
void cs_shared(uint3 id : SV_DispatchThreadID, uint3 gid : SV_GroupID, uint3 tid : SV_GroupThreadID, uint gi : SV_GroupIndex)
{
    cs_shared_mem[gi] = id.x * 0.5;
    GroupMemoryBarrierWithGroupSync();
    cs_shared_out[id.x] = float4(cs_shared_mem[63 - gi], gid.x, tid.x, gi);
}

// Atomics: a counter in a raw buffer (each thread's old value is unique),
// a maximum, a typed uint UAV, and a groupshared sum.
RWByteAddressBuffer cs_atom_counter : register(u0);
RWStructuredBuffer<uint> cs_atom_old : register(u1);
RWTexture2D<uint> cs_atom_grid : register(u2);
groupshared uint cs_atom_group;

[numthreads(32, 1, 1)]
void cs_atomic(uint3 id : SV_DispatchThreadID, uint gi : SV_GroupIndex)
{
    if (gi == 0) cs_atom_group = 0;
    GroupMemoryBarrierWithGroupSync();
    uint old;
    cs_atom_counter.InterlockedAdd(0, 1, old);
    cs_atom_counter.InterlockedMax(4, id.x * 3);
    InterlockedAdd(cs_atom_grid[uint2(id.x & 3, 0)], 1);
    InterlockedAdd(cs_atom_group, id.x);
    GroupMemoryBarrierWithGroupSync();
    cs_atom_old[id.x] = old;
    if (gi == 0) cs_atom_counter.Store(8 + 4 * (id.x / 32), cs_atom_group);
}

// A texture sampled (bilinear, an explicit level) by a compute shader,
// into a typed buffer.
Texture2D<float4> cs_sample_tex : register(t0);
SamplerState cs_sample_smp : register(s0);
RWBuffer<float4> cs_sample_out : register(u0);

[numthreads(4, 4, 1)]
void cs_sample(uint3 id : SV_DispatchThreadID)
{
    uint w, h;
    cs_sample_tex.GetDimensions(w, h);
    float2 uv = (float2(id.xy) + 1.0) / float2(w, h);
    cs_sample_out[id.y * 4 + id.x] = cs_sample_tex.SampleLevel(cs_sample_smp, uv, 0);
}

// Bits, halves and a switch: each thread's word through countbits,
// firstbithigh and firstbitlow (unsigned and signed), reversebits,
// f32tof16 and f16tof32, a bit field put in, and a switch on its low bits
// (kept a switch: [forcecase]).
ByteAddressBuffer cs_bits_in : register(t0);
RWByteAddressBuffer cs_bits_out : register(u0);

[numthreads(32, 1, 1)]
void cs_bits(uint3 id : SV_DispatchThreadID)
{
    uint x = cs_bits_in.Load(id.x * 4);
    int sx = (int)x;
    uint sw;
    [forcecase] switch (x & 3) {
        case 0: sw = 10; break;
        case 1: case 2: sw = 20 + (x & 3); break;
        default: sw = 99; break;
    }
    uint bf = (x & ~0xff0u) | ((sw << 4) & 0xff0u);
    cs_bits_out.Store4(id.x * 32, uint4(countbits(x), firstbithigh(x), firstbitlow(x), reversebits(x)));
    cs_bits_out.Store4(id.x * 32 + 16, uint4(f32tof16(asfloat(x & 0x3fffffffu)), asuint(f16tof32(x)), (uint)firstbithigh(sx), sw + bf * 0 + (bf << 0) - bf + bf));
}

// A local array indexed at run time (an indexable temp, x0[]): filled,
// one entry changed by the thread's index, two read back.
RWByteAddressBuffer cs_xarr_out : register(u0);

[numthreads(16, 1, 1)]
void cs_xarr(uint3 id : SV_DispatchThreadID)
{
    uint a[8];
    [unroll] for (uint i = 0; i < 8; i++) a[i] = i * i + id.x;
    a[id.x & 7] += 100;
    cs_xarr_out.Store(id.x * 4, a[(id.x * 3) & 7] + a[id.x & 7]);
}

// Gather: the four texels around each point, red, then green with an
// offset of -1 across.
Texture2D<float4> cs_gather_tex : register(t0);
SamplerState cs_gather_smp : register(s0);
RWBuffer<float4> cs_gather_out : register(u0);

[numthreads(4, 4, 1)]
void cs_gather(uint3 id : SV_DispatchThreadID)
{
    float2 uv = (float2(id.xy) + 1.0) / 4.0;
    cs_gather_out[(id.y * 4 + id.x) * 2] = cs_gather_tex.GatherRed(cs_gather_smp, uv);
    cs_gather_out[(id.y * 4 + id.x) * 2 + 1] = cs_gather_tex.GatherGreen(cs_gather_smp, uv, int2(-1, 0));
}
