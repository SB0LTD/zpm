// Control flow: loops with break, continue and continuing, a switch with a
// continue inside a loop, functions that return early from loops and
// switches, a private variable, a local array indexed at run time.
@group(0) @binding(0) var<storage, read_write> o: array<u32>;
var<private> acc: u32;

fn collatz(n0: u32) -> u32 {
    var n = n0;
    var steps = 0u;
    loop {
        if (n == 1u) { break; }
        if (steps >= 1000u) { return 0xffffffffu; }
        if ((n & 1u) == 0u) { n = n / 2u; } else { n = 3u * n + 1u; }
        steps++;
        continuing { acc += 1u; }
    }
    return steps;
}

fn classify(x: u32) -> u32 {
    switch (x % 5u) {
        case 0u: { return 10u; }
        case 1u, 2u: { return 20u; }
        default: {
            if (x > 100u) { return 30u; }
            return 40u;
        }
    }
}

@compute @workgroup_size(16)
fn main(@builtin(global_invocation_id) id: vec3<u32>, @builtin(num_workgroups) nw: vec3<u32>) {
    let i = id.x;
    acc = 0u;
    var sum = 0u;
    for (var j = 0u; j < 10u; j++) {
        if (j == 3u) { continue; }
        switch (j) {
            case 5u: { continue; }
            case 7u: { sum += 100u + i; }
            default: { sum += j; }
        }
        if (sum > 1000u) { break; }
    }
    var arr = array<u32, 8>(1u, 2u, 3u, 4u, 5u, 6u, 7u, 8u);
    arr[i % 8u] = i;
    var t = 0u;
    for (var j = 0u; j < 8u; j++) { t += arr[(j + i) % 8u] * (j + 1u); }
    var w = 0u;
    while (w < i) { w += 3u; }
    o[i * 8u + 0u] = collatz(i + 1u);
    o[i * 8u + 1u] = acc;
    o[i * 8u + 2u] = classify(i * 7u);
    o[i * 8u + 3u] = sum;
    o[i * 8u + 4u] = t;
    o[i * 8u + 5u] = w;
    o[i * 8u + 6u] = nw.x;
    let v = vec4<f32>(f32(i), 1.0, 2.0, 3.0);
    o[i * 8u + 7u] = u32(dot(v, v.wzyx));
}
