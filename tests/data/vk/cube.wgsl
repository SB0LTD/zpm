// A cube array sampled in a compute shader (each face of two cubes at its
// centre), and a texture through an anisotropic sampler next to a linear one.
@group(0) @binding(0) var cubes: texture_cube_array<f32>;
@group(0) @binding(1) var nearest: sampler;
@group(0) @binding(2) var<storage, read_write> o: array<vec4<f32>>;
@group(0) @binding(3) var tex: texture_2d<f32>;
@group(0) @binding(4) var aniso: sampler;
@group(0) @binding(5) var linear: sampler;

@compute @workgroup_size(12)
fn main(@builtin(local_invocation_index) i: u32) {
    var dirs = array<vec3<f32>, 6>(vec3(1.0, 0.0, 0.0), vec3(-1.0, 0.0, 0.0), vec3(0.0, 1.0, 0.0), vec3(0.0, -1.0, 0.0), vec3(0.0, 0.0, 1.0), vec3(0.0, 0.0, -1.0));
    o[i] = textureSampleLevel(cubes, nearest, dirs[i % 6u], i32(i / 6u), 0.0);
    let uv = vec2<f32>((f32(i) + 0.3) / 12.0, 0.4);
    o[12u + i] = textureSampleLevel(tex, aniso, uv, 0.0);
    o[24u + i] = textureSampleLevel(tex, linear, uv, 0.0);
}
