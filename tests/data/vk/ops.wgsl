// Integer and float arithmetic, bit operations, conversions and atomics:
// 32 results per thread, checked against the CPU.
@group(0) @binding(0) var<storage, read> a: array<u32>;
@group(0) @binding(1) var<storage, read> b: array<u32>;
@group(0) @binding(2) var<storage, read_write> o: array<u32>;
@group(0) @binding(3) var<storage, read_write> counters: array<atomic<u32>, 4>;
@group(0) @binding(4) var<storage, read_write> scounters: array<atomic<i32>, 2>;

const N: u32 = 32u;

@compute @workgroup_size(32)
fn main(@builtin(global_invocation_id) id: vec3<u32>) {
    let i = id.x;
    let x = a[i];
    let y = b[i];
    let sx = bitcast<i32>(x);
    let sy = bitcast<i32>(y);
    let fx = f32(sx) * 0.25;
    let fy = f32(sy) * 0.5 + 0.75;
    var r: array<u32, N>;
    r[0] = x + y;
    r[1] = x - y;
    r[2] = x * y;
    r[3] = x / y;
    r[4] = x % y;
    r[5] = bitcast<u32>(sx / sy);
    r[6] = bitcast<u32>(sx % sy);
    r[7] = x & y;
    r[8] = x | y;
    r[9] = x ^ y;
    r[10] = ~x;
    r[11] = x << (y & 31u);
    r[12] = x >> (y & 31u);
    r[13] = bitcast<u32>(sx >> (y & 31u));
    r[14] = select(0u, 1u, x < y) | select(0u, 2u, sx < sy) | select(0u, 4u, x == y) | select(0u, 8u, fx <= fy);
    r[15] = bitcast<u32>(fx + fy);
    r[16] = bitcast<u32>(fx - fy);
    r[17] = bitcast<u32>(fx * fy);
    r[18] = bitcast<u32>(fx / fy);
    r[19] = bitcast<u32>(floor(fx / 3.0));
    r[20] = bitcast<u32>(min(fx, fy));
    r[21] = bitcast<u32>(max(fx, fy));
    r[22] = bitcast<u32>(abs(fx));
    r[23] = bitcast<u32>(clamp(fx, -1.0, 1.0));
    r[24] = u32(abs(fy) * 3.0);
    r[25] = bitcast<u32>(i32(fx));
    r[26] = countOneBits(x);
    r[27] = reverseBits(x);
    r[28] = firstLeadingBit(x);
    r[29] = firstTrailingBit(x);
    r[30] = extractBits(x, 3u, 7u);
    r[31] = insertBits(x, y, 5u, 9u);
    for (var k = 0u; k < N; k++) { o[i * N + k] = r[k]; }
    atomicAdd(&counters[0], x & 0xffu);
    atomicMax(&counters[1], x);
    atomicMin(&counters[2], x);
    atomicSub(&counters[3], 1u);
    atomicMin(&scounters[0], sx);
    atomicMax(&scounters[1], sx);
}
