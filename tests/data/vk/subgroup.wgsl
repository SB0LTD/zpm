// Subgroup operations (wgpu's SUBGROUP) and the atomics past add/min/max/
// exchange: a workgroup of 64 lanes (two subgroups of 32), every lane's
// results in o[24 * li ..], some of them in a divergent branch.

@group(0) @binding(0) var<storage, read> a: array<u32>;
@group(0) @binding(1) var<storage, read_write> o: array<u32>;
@group(0) @binding(2) var<storage, read_write> c: array<atomic<u32>>;

@compute @workgroup_size(64)
fn main(@builtin(local_invocation_index) li: u32, @builtin(subgroup_invocation_id) sl: u32, @builtin(subgroup_size) ss: u32) {
    let x = a[li];
    let f = f32(x & 0xffu) * 0.5;
    let b = li * 24u;
    o[b + 0u] = subgroupAdd(x);
    o[b + 1u] = subgroupExclusiveAdd(x);
    o[b + 2u] = subgroupInclusiveAdd(x);
    o[b + 3u] = bitcast<u32>(subgroupAdd(f));
    o[b + 4u] = subgroupMin(x);
    o[b + 5u] = subgroupMax(x);
    o[b + 6u] = subgroupAnd(x);
    o[b + 7u] = subgroupOr(x);
    o[b + 8u] = subgroupXor(x);
    o[b + 9u] = subgroupMul((x & 3u) | 1u);
    o[b + 10u] = subgroupBallot((x & 1u) != 0u).x;
    o[b + 11u] = subgroupBroadcast(x, 5u);
    o[b + 12u] = subgroupBroadcastFirst(x);
    o[b + 13u] = subgroupShuffle(x, (sl * 7u) & 31u);
    o[b + 14u] = subgroupShuffleXor(x, 3u);
    o[b + 15u] = subgroupShuffleUp(x, 2u);
    o[b + 16u] = subgroupShuffleDown(x, 3u);
    o[b + 17u] = u32(subgroupAll(x != 0u)) | (u32(subgroupAny(x == 7u)) << 1u) | (ss << 8u);
    o[b + 18u] = quadBroadcast(x, 2u);
    o[b + 19u] = quadSwapX(x);
    o[b + 20u] = bitcast<u32>(subgroupExclusiveMul(f32((x & 1u) + 1u)));
    if (x % 3u != 0u) {
        o[b + 21u] = subgroupAdd(x);
        o[b + 22u] = subgroupExclusiveAdd(x);
        o[b + 23u] = subgroupBallot(true).x;
    }
    // the atomics: and, or, xor of every x; an increment by compare-exchange
    // (every lane contending); each lane's own word swapped by odd lanes
    atomicAnd(&c[0], x | 0x0f0f0f0fu);
    atomicOr(&c[1], x);
    atomicXor(&c[2], x);
    loop {
        let old = atomicLoad(&c[3]);
        if (atomicCompareExchangeWeak(&c[3], old, old + 1u).exchanged) { break; }
    }
    let want = select(x + 1u, x, (li & 1u) == 1u);
    let r = atomicCompareExchangeWeak(&c[4u + li], want, li);
    o[64u * 24u + 2u * li] = r.old_value;
    o[64u * 24u + 2u * li + 1u] = u32(r.exchanged);
}
