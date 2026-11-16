// Multiview: a full-screen quad drawn once a view, each view's colour from
// ViewIndex (a fragment input, and passed down from the vertex stage).
struct VOut {
    @builtin(position) pos: vec4<f32>,
    @location(0) @interpolate(flat) from_vs: u32,
}

@vertex
fn vs_main(@builtin(vertex_index) vi: u32, @builtin(view_index) view: u32) -> VOut {
    let corners = array<vec2<f32>, 6>(vec2(-1.0, -1.0), vec2(1.0, -1.0), vec2(-1.0, 1.0), vec2(-1.0, 1.0), vec2(1.0, -1.0), vec2(1.0, 1.0));
    var o: VOut;
    o.pos = vec4<f32>(corners[vi], 0.5, 1.0);
    o.from_vs = view + 1u;
    return o;
}

@fragment
fn fs_main(in: VOut, @builtin(view_index) view: u32) -> @location(0) vec4<f32> {
    return vec4<f32>(f32(view) * 0.5, f32(in.from_vs) * 0.25, 0.0, 1.0);
}
