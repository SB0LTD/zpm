// A triangle from a vertex buffer, its colour from the vertices and a
// uniform tint (tests/test_vk.sig draws it on the emulated RTX).
struct VOut {
    @builtin(position) pos: vec4<f32>,
    @location(0) color: vec4<f32>,
}

struct Tint {
    tint: vec4<f32>,
    depth: f32,
}

@group(0) @binding(0) var<uniform> u: Tint;

@vertex
fn vs_main(@location(0) p: vec2<f32>, @location(1) c: vec3<f32>, @builtin(instance_index) inst: u32) -> VOut {
    var o: VOut;
    let dx = f32(inst) * 0.25;
    o.pos = vec4<f32>(p.x + dx, p.y, u.depth, 1.0);
    o.color = vec4<f32>(c, 1.0) * u.tint;
    return o;
}

@fragment
fn fs_main(i: VOut) -> @location(0) vec4<f32> {
    if (i.color.a < 0.01) {
        discard;
    }
    return i.color;
}
