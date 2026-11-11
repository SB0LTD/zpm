// A workgroup reduction: shared memory, a barrier in a loop, push constants (immediates).
struct P { n: u32, scale: f32 }
@group(0) @binding(0) var<storage, read> input: array<f32>;
@group(0) @binding(1) var<storage, read_write> output: array<f32>;
var<immediate> p: P;
var<workgroup> sh: array<f32, 64>;

@compute @workgroup_size(64)
fn main(@builtin(local_invocation_id) lid: vec3<u32>, @builtin(workgroup_id) wid: vec3<u32>) {
    let i = wid.x * 64u + lid.x;
    var v = 0.0;
    if (i < p.n) { v = input[i]; }
    sh[lid.x] = v;
    workgroupBarrier();
    for (var s = 32u; s > 0u; s >>= 1u) {
        if (lid.x < s) { sh[lid.x] += sh[lid.x + s]; }
        workgroupBarrier();
    }
    if (lid.x == 0u) { output[wid.x] = sh[0] * p.scale; }
}
