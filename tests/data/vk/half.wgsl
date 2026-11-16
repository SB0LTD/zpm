// f16 (wgpu's SHADER_F16): halves in storage (scalars and vec2s), their
// arithmetic rounded to half precision, conversions (naga 30 takes no bitcasts of halves).
enable f16;

@group(0) @binding(0) var<storage, read> h: array<f16>;
@group(0) @binding(1) var<storage, read> h2: array<vec2<f16>>;
@group(0) @binding(2) var<storage, read_write> oh: array<f16>;
@group(0) @binding(3) var<storage, read_write> ow: array<u32>;

@compute @workgroup_size(32)
fn main(@builtin(global_invocation_id) gid: vec3<u32>) {
    let i = gid.x;
    let x = h[i];
    let y = h[(i + 7u) % 32u];
    let v = h2[i];
    oh[8u * i + 0u] = x + y;
    oh[8u * i + 1u] = x * y;
    oh[8u * i + 2u] = x / (y + 1.5h);
    oh[8u * i + 3u] = fma(x, y, 0.333h);
    oh[8u * i + 4u] = sqrt(abs(x));
    oh[8u * i + 5u] = f16(f32(x) * 1.0001);
    oh[8u * i + 6u] = v.x - v.y;
    oh[8u * i + 7u] = dot(v, vec2<f16>(x, y));
    ow[4u * i + 0u] = bitcast<u32>(f32(v.x * v.y + x));
    ow[4u * i + 1u] = bitcast<u32>(f32(x * y));
    ow[4u * i + 2u] = u32(i32(x * 4.0h) + 1000);
    ow[4u * i + 3u] = u32(x < y) | (u32(x == y) << 1u);
}
