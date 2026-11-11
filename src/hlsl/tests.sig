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
