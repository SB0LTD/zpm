// Sampled textures in a compute shader: a sampled RGBA8 texture (nearest,
// at texel centres), its texels loaded and its size; an RGBA8 uint one
// (kept widened) loaded.
@group(0) @binding(0) var tex: texture_2d<f32>;
@group(0) @binding(1) var smp: sampler;
@group(0) @binding(2) var<storage, read_write> o: array<vec4<f32>>;
@group(0) @binding(3) var itex: texture_2d<u32>;

@compute @workgroup_size(16)
fn main(@builtin(global_invocation_id) gid: vec3<u32>) {
    let i = gid.x;
    let x = i % 4u;
    let y = i / 4u;
    let uv = (vec2<f32>(f32(x), f32(y)) + 0.5) / 4.0;
    o[3u * i] = textureSampleLevel(tex, smp, uv, 0.0);
    o[3u * i + 1u] = textureLoad(tex, vec2<u32>(x, y), 0);
    let d = textureDimensions(tex);
    let q = textureLoad(itex, vec2<u32>(x, y), 0);
    o[3u * i + 2u] = vec4<f32>(f32(d.x), f32(d.y), f32(q.x), f32(q.w));
}
