// The SPIR-V front end's first shader: buffers, a uniform block, workgroup
// memory and barriers, a loop, a call, arrayLength and an integer modulo.
struct Params { n: u32, scale: f32 }
@group(0) @binding(0) var<storage, read> src: array<f32>;
@group(0) @binding(1) var<storage, read_write> dst: array<f32>;
@group(0) @binding(2) var<uniform> p: Params;
var<workgroup> tile: array<f32, 64>;

fn twice(x: f32) -> f32 { return x * 2.0; }

@compute @workgroup_size(64)
fn main(@builtin(global_invocation_id) gid: vec3<u32>, @builtin(local_invocation_index) li: u32) {
    let i = gid.x;
    var v = 0.0;
    if (i < p.n) { v = src[i]; }
    tile[li] = v;
    workgroupBarrier();
    var s = 0.0;
    for (var k = 0u; k < 64u; k++) { s += tile[k]; }
    if (i < arrayLength(&dst)) { dst[i] = twice(v) * p.scale + s + f32(i % 7u); }
}
