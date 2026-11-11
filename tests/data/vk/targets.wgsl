// Two colour targets from one fragment shader: the first blended (source
// alpha over), the second the fragment's position (tests/test_vk.sig).
struct Out {
    @location(0) a: vec4<f32>,
    @location(1) b: vec4<f32>,
}

@vertex
fn vs_main(@builtin(vertex_index) vi: u32) -> @builtin(position) vec4<f32> {
    // a triangle over the whole target
    let x = f32(i32(vi & 1u) * 4 - 1);
    let y = f32(i32(vi >> 1u) * 4 - 1);
    return vec4<f32>(x, y, 0.0, 1.0);
}

@fragment
fn fs_main(@builtin(position) p: vec4<f32>) -> Out {
    var o: Out;
    o.a = vec4<f32>(0.25, 0.5, 0.75, 0.5);
    o.b = vec4<f32>(p.x / 16.0, p.y / 16.0, 0.0, 1.0);
    return o;
}
