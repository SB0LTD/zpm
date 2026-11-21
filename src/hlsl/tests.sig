//! @zpm/hlsl tests — compiles ANGLE-shaped shaders and checks the
//! containers they make (signatures, reflection, the program), with no
//! other compiler involved. (tests/test_hlsl_oracle.sig compares with
//! Microsoft's compiler where it can run.)

const std = @import("std");
const hlsl = @import("hlsl.sig");
const ct = hlsl.container;
const testing = std.testing;

var compiler: hlsl.Compiler = undefined;

fn compileOk(src: []const u8, target: []const u8) ![]const u8 {
    const r = compiler.compile(src, .{ .target = target });
    if (!r.ok) {
        std.debug.print("{s}\n", .{r.messages});
        return error.CompileFailed;
    }
    return r.blob;
}

test "a vertex shader: a matrix from the globals, a struct in and out" {
    const src =
        \\uniform float4x4 _u_mvp : register(c0);
        \\struct VS_INPUT { float4 pos : TEXCOORD0; float2 uv : TEXCOORD1; };
        \\struct VS_OUTPUT { float4 dx_Position : SV_Position; float2 v0 : TEXCOORD0; };
        \\VS_OUTPUT main(VS_INPUT input) {
        \\    VS_OUTPUT o;
        \\    o.dx_Position = mul(transpose(_u_mvp), input.pos);
        \\    o.v0 = input.uv;
        \\    return o;
        \\}
    ;
    const blob = try compileOk(src, "vs_4_0");
    try testing.expect(ct.findChunk(blob, "SHDR") != null);
    const c = ct.checksum(blob[20..]);
    try testing.expectEqual(c[0], std.mem.readInt(u32, blob[4..8], .little));
    var r: ct.Reflection = undefined;
    try testing.expect(r.read(ct.findChunk(blob, "RDEF").?));
    try testing.expectEqual(@as(u32, 1), r.nbufs);
    try testing.expectEqualStrings("$Globals", r.bufs[0].name);
    try testing.expectEqual(@as(u32, 64), r.vars[0].size);
}

test "preprocessing alone (D3DPreprocess)" {
    const r = compiler.preprocess("#define K 2\nfloat f() { return K * 3; }\n#if K > 1\nint x;\n#endif\n", .{ .target = "ps_4_0" });
    try testing.expect(r.ok);
    try testing.expect(std.mem.indexOf(u8, r.blob, "return 2 * 3") != null);
    try testing.expect(std.mem.indexOf(u8, r.blob, "int x ;") != null);
}

test "signature elements read back" {
    const blob = try compileOk("float4 main(float4 p : SV_Position, float2 uv : TEXCOORD3) : SV_Target { return uv.xyxy; }", "ps_4_0");
    const isg = ct.findChunk(blob, "ISGN").?;
    try testing.expectEqual(@as(u32, 2), ct.sigCount(isg));
    const e = ct.sigElem(isg, false, 1).?;
    try testing.expectEqualStrings("TEXCOORD", e.name);
    try testing.expectEqual(@as(u32, 3), e.index);
    try testing.expectEqual(@as(u8, 3), e.mask);
}

test "nested overloaded calls compile in time (types once per node)" {
    // f(f(f(...))) twenty deep, f overloaded: each level's arguments typed once
    var buf: [4096]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try w.writeAll("float f(float x) { return x * 0.5 + 0.25; }\nfloat2 f(float2 x) { return x.yx; }\n");
    try w.writeAll("float4 main(float4 p : SV_Position) : SV_Target { return ");
    for (0..20) |_| try w.writeAll("f(");
    try w.writeAll("p.x");
    for (0..20) |_| try w.writeAll(")");
    try w.writeAll(".xxxx; }\n");
    _ = try compileOk(w.buffered(), "ps_4_0");
}

test "errors come back as fxc-shaped messages" {
    const r = compiler.compile("float4 main() : SV_Target { return undefined_thing; }", .{ .target = "ps_4_0" });
    try testing.expect(!r.ok);
    try testing.expect(std.mem.indexOf(u8, r.messages, "error") != null);
    try testing.expect(std.mem.indexOf(u8, r.messages, "undefined_thing") != null);
}

test "the compiler's tables fit a DLL's static data" {
    // (demand-paged: only what a compile touches costs memory)
    try testing.expect(@sizeOf(hlsl.Compiler) < 64 << 20);
    std.debug.print("Compiler: {d} MiB\n", .{@sizeOf(hlsl.Compiler) >> 20});
}

/// A compiled shader's binding for `name`: its register, or null.
fn bindOf(blob: []const u8, name: []const u8) ?u32 {
    var r: ct.Reflection = undefined;
    if (!r.read(ct.findChunk(blob, "RDEF").?)) return null;
    for (r.binds[0..r.nbinds]) |b| if (std.mem.eql(u8, b.name, name)) return b.bind;
    return null;
}

test "constant buffers take slots as fxc gives them: only those read" {
    // (fxc 10.1: unread A and $Globals take none; B cb0, C cb1)
    const a = try compileOk("cbuffer A { float4 a; };\n" ++
        "cbuffer B { float4 b; };\n" ++
        "float4 x;\n" ++
        "cbuffer C { float4 cc; };\n" ++
        "float4 main(float4 p : POSITION) : SV_Position { return p * b + cc; }\n", "vs_5_0");
    try testing.expectEqual(@as(?u32, 0), bindOf(a, "B"));
    try testing.expectEqual(@as(?u32, 1), bindOf(a, "C"));
    try testing.expectEqual(@as(?u32, null), bindOf(a, "A"));
    try testing.expectEqual(@as(?u32, null), bindOf(a, "$Globals"));
    // (register(b#) stays; $Globals is placed before the cbuffers: cb1, B cb2)
    const b = try compileOk("cbuffer A { float4 a; };\n" ++
        "cbuffer B { float4 b; };\n" ++
        "float4 x;\n" ++
        "cbuffer C : register(b0) { float4 cc; };\n" ++
        "cbuffer D : register(b3) { float4 dd; };\n" ++
        "float4 main(float4 p : POSITION) : SV_Position { return p * b + cc + x; }\n", "vs_5_0");
    try testing.expectEqual(@as(?u32, 0), bindOf(b, "C"));
    try testing.expectEqual(@as(?u32, 1), bindOf(b, "$Globals"));
    try testing.expectEqual(@as(?u32, 2), bindOf(b, "B"));
    // (an unread register(b1) is still reserved: B cb2)
    const c = try compileOk("cbuffer B { float4 b; };\n" ++
        "cbuffer C : register(b0) { float4 cc; };\n" ++
        "cbuffer D : register(b1) { float4 dd; };\n" ++
        "float4 main(float4 p : POSITION) : SV_Position { return p * b + cc; }\n", "vs_5_0");
    try testing.expectEqual(@as(?u32, 2), bindOf(c, "B"));
}

test "more constant buffers declared than slots, few read" {
    var src: [8192]u8 = undefined;
    var n: usize = 0;
    for (0..40) |i| n += (std.fmt.bufPrint(src[n..], "cbuffer c{d} {{ float4 v{d}; }};\n", .{ i, i }) catch unreachable).len;
    n += (std.fmt.bufPrint(src[n..], "float4 main(float4 p : POSITION) : SV_Position {{ return p * v7 + v39; }}\n", .{}) catch unreachable).len;
    const blob = try compileOk(src[0..n], "vs_5_0");
    try testing.expectEqual(@as(?u32, 0), bindOf(blob, "c7"));
    try testing.expectEqual(@as(?u32, 1), bindOf(blob, "c39"));
}

// ── compute shaders and UAVs ───────────────────────────────────────────────

var listing_buf: [64 * 1024]u8 = undefined;

/// A compiled shader's listing (D3DDisassemble's form).
fn listingOf(blob: []const u8) ![]const u8 {
    const n = try hlsl.disasm.disassemble(blob, &listing_buf);
    return listing_buf[0..n];
}

fn expectListed(text: []const u8, line: []const u8) !void {
    if (std.mem.indexOf(u8, text, line) == null) {
        std.debug.print("not in the listing: {s}\n{s}\n", .{ line, text });
        return error.TestExpectedListing;
    }
}

fn expectNotListed(text: []const u8, line: []const u8) !void {
    if (std.mem.indexOf(u8, text, line) != null) {
        std.debug.print("in the listing, unexpected: {s}\n{s}\n", .{ line, text });
        return error.TestUnexpectedListing;
    }
}

var refl: ct.Reflection = undefined;

fn reflOf(blob: []const u8) !*ct.Reflection {
    try testing.expect(refl.read(ct.findChunk(blob, "RDEF").?));
    return &refl;
}

fn bindingOf(r: *const ct.Reflection, name: []const u8) !ct.RBind {
    for (r.binds[0..r.nbinds]) |b| if (std.mem.eql(u8, b.name, name)) return b;
    std.debug.print("no binding {s}\n", .{name});
    return error.TestNoBinding;
}

fn expectError(src: []const u8, target: []const u8, code: []const u8) !void {
    const r = compiler.compile(src, .{ .target = target });
    if (r.ok or std.mem.indexOf(u8, r.messages, code) == null) {
        std.debug.print("expected {s}, got ok={} {s}\n", .{ code, r.ok, r.messages });
        return error.TestExpectedError;
    }
}

test "compute: numthreads, the thread ids, typed UAVs and textures" {
    const blob = try compileOk(
        \\RWTexture2D<float4> image : register(u0);
        \\RWBuffer<uint> counts;
        \\Texture2D<float4> colors;
        \\SamplerState s;
        \\[numthreads(8, 4, 2)]
        \\void main(uint3 id : SV_DispatchThreadID, uint3 g : SV_GroupID, uint3 t : SV_GroupThreadID, uint i : SV_GroupIndex)
        \\{
        \\    uint w, h;
        \\    image.GetDimensions(w, h);
        \\    uint n;
        \\    counts.GetDimensions(n);
        \\    float4 c = colors.SampleLevel(s, id.xy / 8.0, 0) + colors[id.xy] + colors.Gather(s, id.xy / 8.0);
        \\    image[id.xy] = image[id.xy] + c + float4(w, h, n, g.x + t.y + i);
        \\    counts[id.x] = counts[id.y] + 1;
        \\}
    , "cs_5_0");
    // (no signatures; the compute program type)
    try testing.expectEqual(@as(u32, 0), ct.sigCount(ct.findChunk(blob, "ISGN").?));
    const r = try reflOf(blob);
    try testing.expectEqual(@as(u32, 0x4353_0500), r.program);
    const img = try bindingOf(r, "image");
    try testing.expectEqual(@as(u32, 4), img.type);
    try testing.expectEqual(@as(u32, 5), img.ret);
    try testing.expectEqual(@as(u32, 4), img.dim);
    try testing.expectEqual(@as(u32, 0xd), img.flags);
    const cnt = try bindingOf(r, "counts");
    try testing.expectEqual(@as(u32, 1), cnt.dim);
    try testing.expectEqual(@as(u32, 1), cnt.bind);
    const l = try listingOf(blob);
    try expectListed(l, "cs_5_0");
    try expectListed(l, "dcl_uav_typed_texture2d (float,float,float,float) u0");
    try expectListed(l, "dcl_uav_typed_buffer (uint,uint,uint,uint) u1");
    try expectListed(l, "dcl_input vThreadIDInGroupFlattened\n");
    try expectListed(l, "dcl_input vThreadGroupID.x\n");
    try expectListed(l, "dcl_input vThreadIDInGroup.y\n");
    try expectListed(l, "dcl_input vThreadID.xy\n");
    try expectListed(l, "dcl_thread_group 8, 4, 2");
    try expectListed(l, "ld_uav_typed ");
    try expectListed(l, "store_uav_typed u0.xyzw");
    try expectListed(l, "resinfo_uint ");
    try expectListed(l, "bufinfo ");
    try expectListed(l, "sample_l ");
    try expectListed(l, "gather4 ");
    // (a typed load of four components: SFI0 says so)
    const sfi = ct.findChunk(blob, "SFI0").?;
    try testing.expectEqual(@as(u32, 0x800), std.mem.readInt(u32, sfi[0..4], .little));
}

test "structured and byte address buffers: bindings, layout, $Element" {
    const blob = try compileOk(
        \\struct P { float3 pos; uint flags; float2 uv; float3x3 m; int ids[3]; };
        \\StructuredBuffer<P> pin;
        \\RWStructuredBuffer<P> pout : register(u1);
        \\ByteAddressBuffer rin;
        \\RWByteAddressBuffer rout;
        \\[numthreads(64, 1, 1)]
        \\void main(uint3 id : SV_DispatchThreadID)
        \\{
        \\    P p = pin[id.x];
        \\    uint n, stride, bytes;
        \\    pin.GetDimensions(n, stride);
        \\    rin.GetDimensions(bytes);
        \\    p.flags += n + stride + bytes + rin.Load(id.x * 4) + rin.Load3(id.x * 12).z;
        \\    pout[id.x] = p;
        \\    pout[id.y].m[1].z = 2;
        \\    rout.Store2(id.x * 8, rin.Load2(id.x * 8 + 4));
        \\}
    , "cs_5_0");
    const r = try reflOf(blob);
    const pin = try bindingOf(r, "pin");
    try testing.expectEqual(@as(u32, 5), pin.type);
    try testing.expectEqual(@as(u32, 6), pin.ret);
    // (tight: 12 + 4 + 8 + 36 + 12 bytes)
    try testing.expectEqual(@as(u32, 72), pin.samples);
    const pout = try bindingOf(r, "pout");
    try testing.expectEqual(@as(u32, 6), pout.type);
    try testing.expectEqual(@as(u32, 1), pout.bind);
    try testing.expectEqual(@as(u32, 1), pout.flags);
    try testing.expectEqual(@as(u32, 7), (try bindingOf(r, "rin")).type);
    const rout = try bindingOf(r, "rout");
    try testing.expectEqual(@as(u32, 8), rout.type);
    try testing.expectEqual(@as(u32, 0), rout.bind);
    // each structured buffer described: one $Element of the element's type
    try testing.expectEqual(@as(u32, 2), r.nbufs);
    try testing.expectEqualStrings("pin", r.bufs[0].name);
    try testing.expectEqual(@as(u32, 3), r.bufs[0].kind);
    const el = r.vars[r.bufs[0].first];
    try testing.expectEqualStrings("$Element", el.name);
    try testing.expectEqual(@as(u32, 72), el.size);
    const st = r.types[el.ty];
    try testing.expectEqual(@as(u16, 5), st.nmembers);
    const offs = [_]u32{ 0, 12, 16, 24, 60 };
    for (offs, 0..) |o, k| try testing.expectEqual(o, r.members[st.first + k].offset);
    const l = try listingOf(blob);
    try expectListed(l, "dcl_resource_structured t0, 72");
    try expectListed(l, "dcl_resource_raw t1");
    try expectListed(l, "dcl_uav_raw u0");
    try expectListed(l, "dcl_uav_structured u1, 72");
    try expectListed(l, "ld_structured ");
    try expectListed(l, "store_structured u1.xyz");
    try expectListed(l, "ld_raw ");
    try expectListed(l, "store_raw u0.xy");
    // (m[1].z: column 2's row 1, a column-major matrix's: 24 + 2*12 + 1*4)
    try expectListed(l, "store_structured u1.x, vThreadID.y, l(52), ");
}

test "atomics: with and without the original value, signed and unsigned" {
    const blob = try compileOk(
        \\struct S { uint hits; int low; };
        \\RWBuffer<int> bi;
        \\RWTexture2D<uint> tu;
        \\RWByteAddressBuffer raw;
        \\RWStructuredBuffer<S> sb;
        \\groupshared uint gs;
        \\[numthreads(8, 1, 1)]
        \\void main(uint3 id : SV_DispatchThreadID, uint gi : SV_GroupIndex)
        \\{
        \\    if (gi == 0) gs = 0;
        \\    GroupMemoryBarrierWithGroupSync();
        \\    uint o1, o2, o3;
        \\    InterlockedMin(bi[id.x], -3);
        \\    InterlockedMin(tu[id.xy], 3u);
        \\    InterlockedAdd(tu[id.yx], 2, o1);
        \\    InterlockedCompareExchange(tu[id.xy], 1, 2, o2);
        \\    InterlockedCompareStore(bi[id.y], 4, 5);
        \\    raw.InterlockedOr(id.x * 4, 6, o3);
        \\    InterlockedMax(sb[id.x].low, -1);
        \\    InterlockedAdd(gs, 1);
        \\    InterlockedExchange(sb[id.y].hits, 7, o1);
        \\    raw.Store(id.x * 4 + 64, o1 + o2 + o3);
        \\}
    , "cs_5_0");
    const l = try listingOf(blob);
    try expectListed(l, "atomic_imin u0, ");
    try expectListed(l, "atomic_umin u1, ");
    try expectListed(l, "imm_atomic_iadd ");
    try expectListed(l, "imm_atomic_cmp_exch ");
    try expectListed(l, "atomic_cmp_store u0, ");
    try expectListed(l, "imm_atomic_or ");
    try expectListed(l, "atomic_imax u3, ");
    try expectListed(l, "atomic_iadd g0, ");
    try expectListed(l, "imm_atomic_exch ");
    try expectListed(l, "sync_g_t");
    try expectListed(l, "dcl_tgsm_raw g0, 4");
}

test "groupshared memory: raw and structured, barriers fxc keeps" {
    const blob = try compileOk(
        \\RWStructuredBuffer<float> o;
        \\groupshared float vals[64];
        \\groupshared float4 one;
        \\groupshared uint unused[8];
        \\[numthreads(64, 1, 1)]
        \\void main(uint3 id : SV_DispatchThreadID, uint gi : SV_GroupIndex)
        \\{
        \\    vals[gi] = gi;
        \\    if (gi == 0) one = float4(1, 2, 3, 4);
        \\    GroupMemoryBarrierWithGroupSync();
        \\    o[id.x] = vals[(gi + 1) % 64] + one.z;
        \\    DeviceMemoryBarrier();
        \\}
    , "cs_5_0");
    const l = try listingOf(blob);
    try expectListed(l, "dcl_tgsm_structured g0, 4, 64");
    try expectListed(l, "dcl_tgsm_raw g1, 16");
    try expectNotListed(l, "g2");
    try expectListed(l, "store_structured g0.x");
    try expectListed(l, "ld_raw ");
    try expectListed(l, "sync_g_t");
    // (no UAV touched before the device barrier: fxc drops it)
    try expectNotListed(l, "sync_uglobal");
    // groupshared memory is not reflected
    const r = try reflOf(blob);
    try testing.expectEqual(@as(u32, 1), r.nbinds);
}

test "append, consume and counters" {
    const blob = try compileOk(
        \\struct E { float2 p; uint id; };
        \\AppendStructuredBuffer<E> found;
        \\ConsumeStructuredBuffer<uint> work;
        \\RWStructuredBuffer<uint> tickets;
        \\globallycoherent RWByteAddressBuffer flags;
        \\[numthreads(32, 1, 1)]
        \\void main(uint3 id : SV_DispatchThreadID)
        \\{
        \\    E e; e.p = float2(work.Consume(), 1); e.id = id.x;
        \\    found.Append(e);
        \\    tickets[tickets.IncrementCounter()] = id.x;
        \\    flags.Store(id.x * 4, 1);
        \\}
    , "cs_5_0");
    const r = try reflOf(blob);
    try testing.expectEqual(@as(u32, 9), (try bindingOf(r, "found")).type);
    try testing.expectEqual(@as(u32, 10), (try bindingOf(r, "work")).type);
    try testing.expectEqual(@as(u32, 11), (try bindingOf(r, "tickets")).type);
    const l = try listingOf(blob);
    try expectListed(l, "dcl_uav_structured u0, 12");
    try expectListed(l, "dcl_uav_structured_opc u2, 4");
    try expectListed(l, "dcl_uav_raw_glc u3");
    try expectListed(l, "imm_atomic_alloc ");
    try expectListed(l, "imm_atomic_consume ");
    try expectError(
        \\RWStructuredBuffer<uint> t;
        \\[numthreads(1, 1, 1)] void main(uint3 id : SV_DispatchThreadID) { t[t.IncrementCounter()] = 1; t[t.DecrementCounter()] = 2; }
    , "cs_5_0", "X4595");
}

test "resources take registers in the order declared, used ones only" {
    // (fxc: t2 t0, ta t1-t3, t1 t4; register(u1) kept, the others round it)
    const blob = try compileOk(
        \\Texture2D<float4> unusedT;
        \\Texture2D<float4> t2;
        \\Texture2D<float4> ta[3];
        \\Texture2D<float4> t1;
        \\RWBuffer<float> unusedU;
        \\RWBuffer<float> u2;
        \\RWBuffer<float> u1;
        \\RWBuffer<float> uk : register(u1);
        \\[numthreads(8, 1, 1)] void main(uint3 id : SV_DispatchThreadID)
        \\{
        \\    u1[id.x] = t1[id.xy].x + ta[1][id.xy].y;
        \\    u2[id.x] = t2[id.xy].y + uk[id.x];
        \\}
    , "cs_5_0");
    const r = try reflOf(blob);
    try testing.expectEqual(@as(u32, 0), (try bindingOf(r, "t2")).bind);
    try testing.expectEqual(@as(u32, 2), (try bindingOf(r, "ta[1]")).bind);
    try testing.expectEqual(@as(u32, 4), (try bindingOf(r, "t1")).bind);
    try testing.expectEqual(@as(u32, 0), (try bindingOf(r, "u2")).bind);
    try testing.expectEqual(@as(u32, 1), (try bindingOf(r, "uk")).bind);
    try testing.expectEqual(@as(u32, 2), (try bindingOf(r, "u1")).bind);
    for (r.binds[0..r.nbinds]) |b| try testing.expect(!std.mem.startsWith(u8, b.name, "unused"));
}

test "UAVs in a pixel shader: after its render targets" {
    const blob = try compileOk(
        \\RWTexture2D<unorm float4> h;
        \\RWStructuredBuffer<uint> m : register(u3);
        \\float4 main(float4 p : SV_Position) : SV_Target1
        \\{
        \\    h[uint2(p.xy)] = 1;
        \\    m[uint(p.x)] = 2;
        \\    DeviceMemoryBarrier();
        \\    return h[uint2(p.yx)];
        \\}
    , "ps_5_0");
    const r = try reflOf(blob);
    const h = try bindingOf(r, "h");
    try testing.expectEqual(@as(u32, 2), h.bind);
    try testing.expectEqual(@as(u32, 1), h.ret);
    try testing.expectEqual(@as(u32, 3), (try bindingOf(r, "m")).bind);
    const l = try listingOf(blob);
    try expectListed(l, "dcl_uav_typed_texture2d (unorm,unorm,unorm,unorm) u2");
    try expectListed(l, "sync_uglobal");
    try expectError(
        \\RWTexture2D<float4> a : register(u0);
        \\float4 main(float4 p : SV_Position) : SV_Target1 { a[uint2(p.xy)] = 1; return 0; }
    , "ps_5_0", "X4509");
}

test "compute errors as fxc gives them" {
    const head = "RWBuffer<uint> b; Texture2D<float4> t; SamplerState s;\n";
    try expectError(head ++ "void main(uint3 id : SV_DispatchThreadID) { b[id.x] = 1; }", "cs_5_0", "X3084");
    try expectError(head ++ "[numthreads(64, 32, 1)] void main(uint3 id : SV_DispatchThreadID) { b[id.x] = 1; }", "cs_5_0", "X3655");
    try expectError(head ++ "[numthreads(1, 1, 1)] uint main(uint3 id : SV_DispatchThreadID) : X { return 0; }", "cs_5_0", "X3507");
    try expectError(head ++ "[numthreads(1, 1, 1)] void main(uint3 id : SV_Position) { b[id.x] = 1; }", "cs_5_0", "X4502");
    try expectError(head ++ "[numthreads(1, 1, 1)] void main(uint3 id : SV_DispatchThreadID) { b[id.x] = t.Sample(s, 0).x; }", "cs_5_0", "X4532");
    try expectError(head ++ "[numthreads(1, 1, 1)] void main(uint3 id : SV_DispatchThreadID) { b[id.x] = ddx(id.x); }", "cs_5_0", "X4532");
    try expectError("RWTexture2D<float4> o;\n[numthreads(1, 1, 1)] void main(uint3 id : SV_DispatchThreadID) { o[id.xy].y = 2; }", "cs_5_0", "X4596");
    try expectError("RWTexture2D<float> o;\n[numthreads(1, 1, 1)] void main(uint3 id : SV_DispatchThreadID) { InterlockedAdd(o[id.xy], 1); }", "cs_5_0", "X3681");
    try expectError(head ++ "[numthreads(1, 1, 1)] void main(uint3 id : SV_DispatchThreadID) { uint x = 0; InterlockedAdd(x, 1); b[id.x] = x; }", "cs_5_0", "X3549");
    try expectError(head ++ "[numthreads(1, 1, 1)] void main(uint3 id : SV_DispatchThreadID) { t[id.xy] = 1; }", "cs_5_0", "X3025");
    try expectError(head ++ "float4 main(float4 p : SV_Position) : SV_Target { GroupMemoryBarrierWithGroupSync(); return 0; }", "ps_5_0", "X3664");
    try expectError("groupshared uint g[9000]; RWBuffer<uint> b;\n[numthreads(8, 1, 1)] void main(uint3 id : SV_DispatchThreadID) { g[id.x] = 1; b[id.x] = g[id.x + 1]; }", "cs_5_0", "X4586");
    // (an unknown target names the compute one among those it takes)
    try expectError("void main() {}", "cs_4_0", "cs_5_0");
}
