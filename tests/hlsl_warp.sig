//! The HLSL oracle's second renderer: Windows' own Direct3D 11 on WARP
//! (its software rasterizer: the same answers every run), for the programs
//! zpm's front end cannot draw yet (switch, cube maps, texture arrays,
//! comparison samplers, indexable temps, geometry shaders). One draw: a
//! vertex shader (and a geometry shader) and a pixel shader into a 16x16
//! RGBA32F target, with constant buffers, textures and samplers made from
//! the shaders' reflection; the pixels read back. Windows only (the oracle
//! test skips elsewhere); test code, never shipped.

const std = @import("std");
const builtin = @import("builtin");
const hlsl = @import("hlsl");
const ct = hlsl.container;

pub const W = 16;
pub const H = 16;

const HRESULT = i32;

const k32 = if (builtin.os.tag == .windows) struct {
    extern "kernel32" fn LoadLibraryA(name: [*:0]const u8) callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn GetProcAddress(m: *anyopaque, name: [*:0]const u8) callconv(.winapi) ?*const anyopaque;
} else struct {};

const D3D11CreateDeviceFn = *const fn (adapter: ?*anyopaque, driver: u32, software: ?*anyopaque, flags: u32, levels: ?[*]const u32, nlevels: u32, sdk: u32, dev: *?*anyopaque, level: ?*u32, ctx: *?*anyopaque) callconv(.winapi) HRESULT;

/// A COM method by vtable index, called with `args` after `this`.
fn call(comptime R: type, obj: *anyopaque, index: usize, args: anytype) R {
    const vt: *const [*]const *const anyopaque = @ptrCast(@alignCast(obj));
    const f = vt.*[index];
    const cc: std.builtin.CallingConvention = .winapi;
    return switch (args.len) {
        0 => @as(*const fn (*anyopaque) callconv(cc) R, @ptrCast(f))(obj),
        1 => @as(*const fn (*anyopaque, @TypeOf(args[0])) callconv(cc) R, @ptrCast(f))(obj, args[0]),
        2 => @as(*const fn (*anyopaque, @TypeOf(args[0]), @TypeOf(args[1])) callconv(cc) R, @ptrCast(f))(obj, args[0], args[1]),
        3 => @as(*const fn (*anyopaque, @TypeOf(args[0]), @TypeOf(args[1]), @TypeOf(args[2])) callconv(cc) R, @ptrCast(f))(obj, args[0], args[1], args[2]),
        4 => @as(*const fn (*anyopaque, @TypeOf(args[0]), @TypeOf(args[1]), @TypeOf(args[2]), @TypeOf(args[3])) callconv(cc) R, @ptrCast(f))(obj, args[0], args[1], args[2], args[3]),
        5 => @as(*const fn (*anyopaque, @TypeOf(args[0]), @TypeOf(args[1]), @TypeOf(args[2]), @TypeOf(args[3]), @TypeOf(args[4])) callconv(cc) R, @ptrCast(f))(obj, args[0], args[1], args[2], args[3], args[4]),
        else => @compileError("call: arity"),
    };
}

fn release(obj: ?*anyopaque) void {
    if (obj) |o| _ = call(u32, o, 2, .{});
}

// ID3D11Device
const CreateBuffer = 3;
const CreateTexture2D = 5;
const CreateShaderResourceView = 7;
const CreateRenderTargetView = 9;
const CreateInputLayout = 11;
const CreateVertexShader = 12;
const CreateGeometryShader = 13;
const CreatePixelShader = 15;
const CreateRasterizerState = 22;
const CreateSamplerState = 23;
// ID3D11DeviceContext
const VSSetConstantBuffers = 7;
const PSSetShaderResources = 8;
const PSSetShader = 9;
const PSSetSamplers = 10;
const VSSetShader = 11;
const DrawCall = 13;
const Map = 14;
const Unmap = 15;
const PSSetConstantBuffers = 16;
const IASetInputLayout = 17;
const IASetVertexBuffers = 18;
const GSSetConstantBuffers = 22;
const GSSetShader = 23;
const IASetPrimitiveTopology = 24;
const VSSetShaderResources = 25;
const VSSetSamplers = 26;
const GSSetShaderResources = 31;
const GSSetSamplers = 32;
const OMSetRenderTargets = 33;
const RSSetState = 43;
const RSSetViewports = 44;
const CopyResource = 47;
const ClearRenderTargetView = 50;
const ClearState = 110;

const BufferDesc = extern struct { ByteWidth: u32, Usage: u32, BindFlags: u32, CPUAccessFlags: u32, MiscFlags: u32, StructureByteStride: u32 };
const SubresourceData = extern struct { pSysMem: ?*const anyopaque, SysMemPitch: u32, SysMemSlicePitch: u32 };
const Tex2DDesc = extern struct { Width: u32, Height: u32, MipLevels: u32, ArraySize: u32, Format: u32, SampleCount: u32, SampleQuality: u32, Usage: u32, BindFlags: u32, CPUAccessFlags: u32, MiscFlags: u32 };
const InputElement = extern struct { SemanticName: [*:0]const u8, SemanticIndex: u32, Format: u32, InputSlot: u32, AlignedByteOffset: u32, InputSlotClass: u32, InstanceDataStepRate: u32 };
const Viewport = extern struct { TopLeftX: f32, TopLeftY: f32, Width: f32, Height: f32, MinDepth: f32, MaxDepth: f32 };
const MappedSubresource = extern struct { pData: ?[*]u8, RowPitch: u32, DepthPitch: u32 };
const SamplerDesc = extern struct { Filter: u32, AddressU: u32, AddressV: u32, AddressW: u32, MipLODBias: f32, MaxAnisotropy: u32, ComparisonFunc: u32, BorderColor: [4]f32, MinLOD: f32, MaxLOD: f32 };
const RasterizerDesc = extern struct { FillMode: u32, CullMode: u32, FrontCounterClockwise: i32, DepthBias: i32, DepthBiasClamp: f32, SlopeScaledDepthBias: f32, DepthClipEnable: i32, ScissorEnable: i32, MultisampleEnable: i32, AntialiasedLineEnable: i32 };
const SrvDesc = extern struct { Format: u32, ViewDimension: u32, a: u32, b: u32, c: u32, d: u32 };

const FMT_RGBA32F = 2;
const FMT_RGBA32U = 3;
const FMT_RGBA32I = 4;
const FMT_RGBA8 = 28;
const FMT_R32F = 41;

var dev: ?*anyopaque = null;
var ctx: ?*anyopaque = null;
var tried = false;

/// The WARP device (null where there is none).
pub fn device() bool {
    if (builtin.os.tag != .windows) return false;
    if (tried) return dev != null;
    tried = true;
    const m = k32.LoadLibraryA("d3d11.dll") orelse return false;
    const create: D3D11CreateDeviceFn = @ptrCast(k32.GetProcAddress(m, "D3D11CreateDevice") orelse return false);
    const levels = [_]u32{0xb000};
    var d: ?*anyopaque = null;
    var c: ?*anyopaque = null;
    if (create(null, 5, null, 0, &levels, 1, 7, &d, null, &c) < 0) return false;
    dev = d;
    ctx = c;
    return true;
}

pub const Stage = struct {
    blob: []const u8,
    /// its constant buffers' words, by slot (empty: none)
    cbs: [16][]const u32 = [_][]const u32{&.{}} ** 16,
};

/// Each vertex input element's data: 3 vertices of 4 words each.
pub const Attr = struct { name: [:0]const u8, index: u32, format: u32, data: [3][4]u32 };

pub const Draw = struct {
    vs: Stage,
    gs: ?Stage = null,
    ps: Stage,
    attrs: []const Attr,
    vertices: u32 = 3,
    /// D3D11_PRIMITIVE_TOPOLOGY: 4 triangle list, 1 point list
    topology: u32 = 4,
};

var cb_objs: [48]?*anyopaque = [_]?*anyopaque{null} ** 48;

/// Draws; the 16x16 RGBA32F pixels into `out`. An error names the step.
pub fn draw(d: Draw, out: *[W * H * 4]f32) error{ NoDevice, Target, Shader, Layout, Buffer, Resource, Readback }!void {
    const D = dev orelse return error.NoDevice;
    const C = ctx.?;
    var objs: [128]?*anyopaque = [_]?*anyopaque{null} ** 128;
    var nobj: usize = 0;
    // (unbound before they are released)
    defer {
        call(void, C, ClearState, .{});
        for (objs[0..nobj]) |o| release(o);
    }
    const keep = struct {
        fn f(list: *[128]?*anyopaque, n: *usize, o: ?*anyopaque) void {
            if (n.* < list.len) {
                list[n.*] = o;
                n.* += 1;
            }
        }
    }.f;
    // the target and its staging copy
    var td = Tex2DDesc{ .Width = W, .Height = H, .MipLevels = 1, .ArraySize = 1, .Format = FMT_RGBA32F, .SampleCount = 1, .SampleQuality = 0, .Usage = 0, .BindFlags = 0x20, .CPUAccessFlags = 0, .MiscFlags = 0 };
    var rt: ?*anyopaque = null;
    if (call(HRESULT, D, CreateTexture2D, .{ &td, @as(?*const SubresourceData, null), &rt }) < 0) return error.Target;
    keep(&objs, &nobj, rt);
    var rtv: ?*anyopaque = null;
    if (call(HRESULT, D, CreateRenderTargetView, .{ rt.?, @as(?*const anyopaque, null), &rtv }) < 0) return error.Target;
    keep(&objs, &nobj, rtv);
    // the shaders
    var vs: ?*anyopaque = null;
    var ps: ?*anyopaque = null;
    var gs: ?*anyopaque = null;
    if (call(HRESULT, D, CreateVertexShader, .{ d.vs.blob.ptr, d.vs.blob.len, @as(?*anyopaque, null), &vs }) < 0) return error.Shader;
    keep(&objs, &nobj, vs);
    if (call(HRESULT, D, CreatePixelShader, .{ d.ps.blob.ptr, d.ps.blob.len, @as(?*anyopaque, null), &ps }) < 0) return error.Shader;
    keep(&objs, &nobj, ps);
    if (d.gs) |g| {
        if (call(HRESULT, D, CreateGeometryShader, .{ g.blob.ptr, g.blob.len, @as(?*anyopaque, null), &gs }) < 0) return error.Shader;
        keep(&objs, &nobj, gs);
    }
    // the input layout and its buffers (a slot per element)
    var els: [16]InputElement = undefined;
    var vbs: [16]?*anyopaque = [_]?*anyopaque{null} ** 16;
    var strides: [16]u32 = [_]u32{16} ** 16;
    var offs: [16]u32 = [_]u32{0} ** 16;
    for (d.attrs, 0..) |a, k| {
        els[k] = .{ .SemanticName = a.name.ptr, .SemanticIndex = a.index, .Format = a.format, .InputSlot = @intCast(k), .AlignedByteOffset = 0, .InputSlotClass = 0, .InstanceDataStepRate = 0 };
        const bd = BufferDesc{ .ByteWidth = 48, .Usage = 0, .BindFlags = 1, .CPUAccessFlags = 0, .MiscFlags = 0, .StructureByteStride = 0 };
        const init = SubresourceData{ .pSysMem = &a.data, .SysMemPitch = 0, .SysMemSlicePitch = 0 };
        if (call(HRESULT, D, CreateBuffer, .{ &bd, &init, &vbs[k] }) < 0) return error.Buffer;
        keep(&objs, &nobj, vbs[k]);
    }
    var layout: ?*anyopaque = null;
    if (d.attrs.len > 0) {
        if (call(HRESULT, D, CreateInputLayout, .{ &els, @as(u32, @intCast(d.attrs.len)), d.vs.blob.ptr, d.vs.blob.len, &layout }) < 0) return error.Layout;
        keep(&objs, &nobj, layout);
    }
    // each stage's constant buffers, textures, samplers
    const stages = [_]struct { st: ?Stage, cb: usize, srv: usize, smp: usize }{
        .{ .st = d.vs, .cb = VSSetConstantBuffers, .srv = VSSetShaderResources, .smp = VSSetSamplers },
        .{ .st = d.gs, .cb = GSSetConstantBuffers, .srv = GSSetShaderResources, .smp = GSSetSamplers },
        .{ .st = d.ps, .cb = PSSetConstantBuffers, .srv = PSSetShaderResources, .smp = PSSetSamplers },
    };
    for (stages) |s| {
        const st = s.st orelse continue;
        var cbs: [16]?*anyopaque = [_]?*anyopaque{null} ** 16;
        for (st.cbs, 0..) |words, slot| {
            if (words.len == 0) continue;
            const bd = BufferDesc{ .ByteWidth = @intCast((words.len * 4 + 15) / 16 * 16), .Usage = 0, .BindFlags = 4, .CPUAccessFlags = 0, .MiscFlags = 0, .StructureByteStride = 0 };
            const init = SubresourceData{ .pSysMem = words.ptr, .SysMemPitch = 0, .SysMemSlicePitch = 0 };
            if (call(HRESULT, D, CreateBuffer, .{ &bd, &init, &cbs[slot] }) < 0) return error.Buffer;
            keep(&objs, &nobj, cbs[slot]);
        }
        call(void, C, s.cb, .{ @as(u32, 0), @as(u32, 14), &cbs });
        try resources(D, C, st.blob, s.srv, s.smp, &objs, &nobj);
    }
    // the draw
    call(void, C, VSSetShader, .{ vs.?, @as(?*anyopaque, null), @as(u32, 0) });
    call(void, C, GSSetShader, .{ gs, @as(?*anyopaque, null), @as(u32, 0) });
    call(void, C, PSSetShader, .{ ps.?, @as(?*anyopaque, null), @as(u32, 0) });
    if (layout) |l| call(void, C, IASetInputLayout, .{l});
    if (d.attrs.len > 0) call(void, C, IASetVertexBuffers, .{ @as(u32, 0), @as(u32, @intCast(d.attrs.len)), &vbs, &strides, &offs });
    call(void, C, IASetPrimitiveTopology, .{d.topology});
    const rd = RasterizerDesc{ .FillMode = 3, .CullMode = 1, .FrontCounterClockwise = 0, .DepthBias = 0, .DepthBiasClamp = 0, .SlopeScaledDepthBias = 0, .DepthClipEnable = 1, .ScissorEnable = 0, .MultisampleEnable = 0, .AntialiasedLineEnable = 0 };
    var rs: ?*anyopaque = null;
    if (call(HRESULT, D, CreateRasterizerState, .{ &rd, &rs }) >= 0) {
        keep(&objs, &nobj, rs);
        call(void, C, RSSetState, .{rs.?});
    }
    const vp = Viewport{ .TopLeftX = 0, .TopLeftY = 0, .Width = W, .Height = H, .MinDepth = 0, .MaxDepth = 1 };
    call(void, C, RSSetViewports, .{ @as(u32, 1), &vp });
    const zero = [4]f32{ 0, 0, 0, 0 };
    call(void, C, ClearRenderTargetView, .{ rtv.?, &zero });
    var rtvs = [_]?*anyopaque{rtv};
    call(void, C, OMSetRenderTargets, .{ @as(u32, 1), &rtvs, @as(?*anyopaque, null) });
    call(void, C, DrawCall, .{ d.vertices, @as(u32, 0) });
    // read back
    td.Usage = 3; // staging
    td.BindFlags = 0;
    td.CPUAccessFlags = 0x20000; // read
    var staging: ?*anyopaque = null;
    if (call(HRESULT, D, CreateTexture2D, .{ &td, @as(?*const SubresourceData, null), &staging }) < 0) return error.Readback;
    keep(&objs, &nobj, staging);
    call(void, C, CopyResource, .{ staging.?, rt.? });
    var m: MappedSubresource = undefined;
    if (call(HRESULT, C, Map, .{ staging.?, @as(u32, 0), @as(u32, 1), @as(u32, 0), &m }) < 0) return error.Readback;
    for (0..H) |y| {
        const row: [*]align(1) const f32 = @ptrCast(m.pData.? + y * m.RowPitch);
        for (0..W * 4) |k| out[y * W * 4 + k] = row[k];
    }
    call(void, C, Unmap, .{ staging.?, @as(u32, 0) });
}

/// Textures and samplers for every binding the shader's reflection names.
fn resources(D: *anyopaque, C: *anyopaque, blob: []const u8, srv_at: usize, smp_at: usize, objs: *[128]?*anyopaque, nobj: *usize) error{Resource}!void {
    var r: ct.Reflection = undefined;
    const rdef = ct.findChunk(blob, "RDEF") orelse return;
    if (!r.read(rdef)) return;
    var srvs: [16]?*anyopaque = [_]?*anyopaque{null} ** 16;
    var smps: [16]?*anyopaque = [_]?*anyopaque{null} ** 16;
    for (r.binds[0..r.nbinds]) |b| {
        var k: u32 = 0;
        while (k < b.count) : (k += 1) {
            const slot = b.bind + k;
            if (slot >= 16) continue;
            if (b.type == 3) {
                const cmp = b.flags & 2 != 0;
                const sd = SamplerDesc{ .Filter = if (cmp) 0x80 else 0, .AddressU = 1, .AddressV = 1, .AddressW = 1, .MipLODBias = 0, .MaxAnisotropy = 1, .ComparisonFunc = if (cmp) 4 else 1, .BorderColor = .{ 0, 0, 0, 0 }, .MinLOD = 0, .MaxLOD = 1000 };
                if (call(HRESULT, D, CreateSamplerState, .{ &sd, &smps[slot] }) < 0) return error.Resource;
                if (nobj.* < objs.len) {
                    objs[nobj.*] = smps[slot];
                    nobj.* += 1;
                }
            } else if (b.type == 2) {
                srvs[slot] = try texture(D, b, isDepth(b), objs, nobj);
            }
        }
    }
    call(void, C, srv_at, .{ @as(u32, 0), @as(u32, 16), &srvs });
    call(void, C, smp_at, .{ @as(u32, 0), @as(u32, 16), &smps });
}

/// An 8x8 texture of the binding's dimension (a cube's 6 faces, an
/// array's 2 layers), every texel different; R32F for a depth compare.
/// A texture sampled with a comparison sampler: ANGLE names them
/// textures*_comparison (and so does the corpus).
pub fn isDepth(b: ct.RBind) bool {
    return std.mem.indexOf(u8, b.name, "comparison") != null;
}

const Tex3DDesc = extern struct { Width: u32, Height: u32, Depth: u32, MipLevels: u32, Format: u32, Usage: u32, BindFlags: u32, CPUAccessFlags: u32, MiscFlags: u32 };
const CreateTexture3D = 6;

fn texture(D: *anyopaque, b: ct.RBind, depth: bool, objs: *[128]?*anyopaque, nobj: *usize) error{Resource}!?*anyopaque {
    const cube = b.dim == 9;
    const array = b.dim == 5;
    const volume = b.dim == 8;
    const layers: u32 = if (cube) 6 else if (array or volume) 2 else 1;
    const fmt: u32 = if (depth) FMT_R32F else switch (b.ret) {
        3 => FMT_RGBA32I,
        4 => FMT_RGBA32U,
        else => FMT_RGBA8,
    };
    const bpp: u32 = switch (fmt) {
        FMT_R32F, FMT_RGBA8 => 4,
        else => 16,
    };
    const S = struct {
        var texels: [6][8 * 8 * 16]u8 = undefined;
    };
    var inits: [6]SubresourceData = undefined;
    for (0..layers) |l| {
        for (0..64) |i| {
            const x: u32 = @intCast(i % 8);
            const y: u32 = @intCast(i / 8);
            const t = S.texels[l][i * bpp ..];
            switch (fmt) {
                FMT_R32F => std.mem.writeInt(u32, t[0..4], @bitCast(@as(f32, @floatFromInt(x * 32)) / 255.0), .little),
                FMT_RGBA8 => {
                    t[0] = @intCast(x * 32);
                    t[1] = @intCast(y * 32);
                    t[2] = @intCast((l * 40 + ((x ^ y) & 1) * 100) % 256);
                    t[3] = @intCast(128 + x * 8);
                },
                else => for (0..4) |c| std.mem.writeInt(u32, t[c * 4 ..][0..4], @intCast(x + y * 8 + c + l), .little),
            }
        }
        inits[l] = .{ .pSysMem = &S.texels[l], .SysMemPitch = 8 * bpp, .SysMemSlicePitch = 0 };
    }
    var tex: ?*anyopaque = null;
    if (volume) {
        // (one 8x8x2 volume: its slices one after the other)
        const S3 = struct {
            var slab: [2 * 8 * 8 * 16]u8 = undefined;
        };
        for (0..2) |l| @memcpy(S3.slab[l * 64 * bpp ..][0 .. 64 * bpp], S.texels[l][0 .. 64 * bpp]);
        const t3 = Tex3DDesc{ .Width = 8, .Height = 8, .Depth = 2, .MipLevels = 1, .Format = fmt, .Usage = 0, .BindFlags = 8, .CPUAccessFlags = 0, .MiscFlags = 0 };
        const init3 = SubresourceData{ .pSysMem = &S3.slab, .SysMemPitch = 8 * bpp, .SysMemSlicePitch = 64 * bpp };
        if (call(HRESULT, D, CreateTexture3D, .{ &t3, &init3, &tex }) < 0) return error.Resource;
    } else {
        const td = Tex2DDesc{ .Width = 8, .Height = 8, .MipLevels = 1, .ArraySize = layers, .Format = fmt, .SampleCount = 1, .SampleQuality = 0, .Usage = 0, .BindFlags = 8, .CPUAccessFlags = 0, .MiscFlags = if (cube) 4 else 0 };
        if (call(HRESULT, D, CreateTexture2D, .{ &td, &inits, &tex }) < 0) return error.Resource;
    }
    if (nobj.* < objs.len) {
        objs[nobj.*] = tex;
        nobj.* += 1;
    }
    // (the view's dimension as the shader declares it: a cube, an array, 2D)
    const vd = SrvDesc{ .Format = fmt, .ViewDimension = if (cube) 9 else if (array) 5 else if (volume) 8 else 4, .a = 0, .b = 1, .c = 0, .d = layers };
    var srv: ?*anyopaque = null;
    if (call(HRESULT, D, CreateShaderResourceView, .{ tex.?, &vd, &srv }) < 0) return error.Resource;
    if (nobj.* < objs.len) {
        objs[nobj.*] = srv;
        nobj.* += 1;
    }
    return srv;
}
