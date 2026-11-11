// Storage textures in a compute shader (WebGPU's texture_storage_*):
// read one rgba8unorm image, write another (channels swapped, alpha
// inverted), add into a layer of an r32float array (read_write), and
// report the sizes the shader sees.
@group(0) @binding(0) var src: texture_storage_2d<rgba8unorm, read>;
@group(0) @binding(1) var dst: texture_storage_2d<rgba8unorm, write>;
@group(0) @binding(2) var acc: texture_storage_2d_array<r32float, read_write>;
@group(0) @binding(3) var<storage, read_write> sizes: array<u32>;

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3<u32>) {
    let d = textureDimensions(dst);
    if (id.x == 0u && id.y == 0u) {
        sizes[0] = d.x;
        sizes[1] = d.y;
        sizes[2] = textureNumLayers(acc);
        let a = textureDimensions(acc);
        sizes[3] = a.x;
    }
    if (id.x >= d.x || id.y >= d.y) {
        return;
    }
    let c = textureLoad(src, vec2<i32>(id.xy));
    textureStore(dst, vec2<i32>(id.xy), vec4<f32>(c.b, c.g, c.r, 1.0 - c.a));
    let v = textureLoad(acc, vec2<i32>(id.xy), 1);
    textureStore(acc, vec2<i32>(id.xy), 1, vec4<f32>(v.x + f32(id.x) * 10.0 + f32(id.y), 0.0, 0.0, 0.0));
}
