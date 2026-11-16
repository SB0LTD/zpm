// Storage textures written by a fragment shader (FRAGMENT_WRITABLE_STORAGE):
// a full-screen quad, each fragment storing its position at its own texel
// of an rgba8unorm storage texture as well as writing its colour.
struct VOut {
    @builtin(position) pos: vec4<f32>,
}

@group(0) @binding(0) var img: texture_storage_2d<rgba8unorm, write>;

@vertex
fn vs_main(@builtin(vertex_index) vi: u32) -> VOut {
    let corners = array<vec2<f32>, 6>(vec2(-1.0, -1.0), vec2(1.0, -1.0), vec2(-1.0, 1.0), vec2(-1.0, 1.0), vec2(1.0, -1.0), vec2(1.0, 1.0));
    var o: VOut;
    o.pos = vec4<f32>(corners[vi], 0.5, 1.0);
    return o;
}

@fragment
fn fs_main(@builtin(position) pos: vec4<f32>) -> @location(0) vec4<f32> {
    let c = vec4<f32>(pos.x / 16.0, pos.y / 16.0, 0.25, 1.0);
    textureStore(img, vec2<i32>(floor(pos.xy)), c);
    return vec4<f32>(0.0, 0.0, 1.0, 1.0);
}
