// A textured quad: its corners from the vertex index, its texels through a
// sampler (nearest or linear), and a second target from the same fragment
// (tests/test_vk.sig draws it on the emulated RTX).
struct VOut {
    @builtin(position) pos: vec4<f32>,
    @location(0) uv: vec2<f32>,
}

struct Params {
    scale: vec2<f32>,
    level: f32,
}

@group(0) @binding(0) var tex: texture_2d<f32>;
@group(0) @binding(1) var samp: sampler;
@group(1) @binding(0) var<uniform> params: Params;
@group(1) @binding(1) var arr: texture_2d_array<f32>;

@vertex
fn vs_main(@builtin(vertex_index) vi: u32) -> VOut {
    let x = f32(vi & 1u);
    let y = f32(vi >> 1u);
    var o: VOut;
    o.pos = vec4<f32>((x * 2.0 - 1.0) * params.scale.x, (1.0 - y * 2.0) * params.scale.y, 0.0, 1.0);
    o.uv = vec2<f32>(x, y);
    return o;
}

@fragment
fn fs_main(i: VOut) -> @location(0) vec4<f32> {
    return textureSample(tex, samp, i.uv);
}

@fragment
fn fs_lod(i: VOut) -> @location(0) vec4<f32> {
    return textureSampleLevel(tex, samp, i.uv, params.level);
}

@fragment
fn fs_fetch(i: VOut) -> @location(0) vec4<f32> {
    let size = textureDimensions(arr, 0);
    let p = vec2<i32>(i.uv * vec2<f32>(size));
    return textureLoad(arr, p, 1, 0);
}
