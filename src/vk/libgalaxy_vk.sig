//! @zpm/vk libgalaxy_vk — the root of libvulkan_galaxy.so, Galaxy's Vulkan
//! driver as an ICD for the Vulkan loader (Alpine's vulkan-loader finds it
//! through /usr/share/vulkan/icd.d/galaxy_icd.json, galaxy_icd.json here).
//!
//! It exports what the loader calls (interface version 5):
//! vk_icdNegotiateLoaderICDInterfaceVersion, vk_icdGetInstanceProcAddr and
//! vk_icdGetPhysicalDeviceProcAddr; every other entry point is found
//! through them (icd.sig's table). The GPU is Galaxy's render node
//! (gfxapi's node.Gpu, the same client EGL uses), with this image's
//! backend: sm_120 on x86-64 (the PC's RTX), ir3 on AArch64. It is opened at
//! the first vkEnumeratePhysicalDevices; without one the instance has no
//! physical device.
//!
//! Built as Galaxy builds libgalaxy-gl.so (scripts/build-gl.sh):
//!   sig build-lib -dynamic -target x86_64-linux-none -OReleaseSafe -fPIC
//!     --name vulkan_galaxy --dep vk --dep gpu --dep gfxapi -Mroot=src/vk/libgalaxy_vk.sig
//!     --dep gpu --dep spirv -Mvk=src/vk/vk.sig --dep gpu -Mspirv=src/spirv/spirv.sig
//!     (gfxapi, gpu, nvidia, adreno, amdgpu as build-gl.sh wires them)

const std = @import("std");
const builtin = @import("builtin");
const gpu = @import("gpu");
const gfxapi = @import("gfxapi");
const vk = @import("vk");
const icd = vk.icd;
const node = gfxapi.node;

pub const panic = if (builtin.os.tag == .linux) std.debug.FullPanic(stop) else std.debug.FullPanic(std.debug.defaultPanic);

fn stop(msg: []const u8, ra: ?usize) noreturn {
    @branchHint(.cold);
    _ = ra;
    const linux = std.os.linux;
    const head = "libvulkan_galaxy: ";
    _ = linux.write(2, head, head.len);
    _ = linux.write(2, msg.ptr, msg.len);
    _ = linux.write(2, "\n", 1);
    linux.exit_group(134);
}

const targets: []const gpu.Target = if (builtin.cpu.arch == .aarch64) &.{.ir3_a7xx} else &.{.sm_120};
const work_bytes = if (builtin.cpu.arch == .aarch64) gpu.kir_ir3.WORK_BYTES else gpu.nvidia_device.kir_sm120.WORK_BYTES;
const G = node.Gpu(node.Linux, targets);

/// (undefined until opened: in .bss)
var the_gpu: G = undefined;
var compile_work: [work_bytes]u8 align(64) = undefined;

fn open() ?icd.Gpu {
    if (comptime builtin.os.tag != .linux) return null;
    the_gpu = .{ .node = .{ .sys = .{} } };
    const d = the_gpu.open() catch |err| {
        var buf: [128]u8 = undefined;
        log(std.fmt.bufPrint(&buf, "no GPU ({s}): no physical device", .{@errorName(err)}) catch "no GPU");
        return null;
    };
    return .{ .dev = d, .compile = G.compile, .work = &compile_work };
}

fn log(msg: []const u8) void {
    if (comptime builtin.os.tag != .linux) return;
    const linux = std.os.linux;
    const head = "Galaxy Vulkan: ";
    _ = linux.write(2, head, head.len);
    _ = linux.write(2, msg.ptr, msg.len);
    _ = linux.write(2, "\n", 1);
}

fn install() void {
    if (icd.opener == null) icd.opener = &open;
    if (icd.log_fn == null) icd.log_fn = &log;
}

export fn vk_icdNegotiateLoaderICDInterfaceVersion(version: ?*u32) callconv(.c) i32 {
    install();
    return icd.negotiate(version);
}

export fn vk_icdGetInstanceProcAddr(instance: ?*anyopaque, name: ?[*:0]const u8) callconv(.c) icd.PFN {
    install();
    return icd.getInstanceProcAddr(instance, name);
}

export fn vk_icdGetPhysicalDeviceProcAddr(instance: ?*anyopaque, name: ?[*:0]const u8) callconv(.c) icd.PFN {
    install();
    return icd.getPhysicalDeviceProcAddr(instance, name);
}

test "the library's entry points answer the loader" {
    var v: u32 = 6;
    try std.testing.expectEqual(@as(i32, 0), vk_icdNegotiateLoaderICDInterfaceVersion(&v));
    try std.testing.expectEqual(icd.ICD_INTERFACE_VERSION, v);
    try std.testing.expect(vk_icdGetInstanceProcAddr(null, "vkCreateInstance") != null);
    try std.testing.expect(vk_icdGetPhysicalDeviceProcAddr(null, "vkGetPhysicalDeviceFeatures2") != null);
    try std.testing.expect(vk_icdGetInstanceProcAddr(null, "vkNoSuchFunction") == null);
}
